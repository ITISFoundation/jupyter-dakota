ARG JUPYTER_MINIMAL_VERSION=lab-3.3.2@sha256:a4bf48221bfa864759e0f248affec3df1af0a68ee3e43dfc7435d84926ec92e8
FROM jupyter/minimal-notebook:${JUPYTER_MINIMAL_VERSION} as base


LABEL maintainer="iavarone"

ENV JUPYTER_ENABLE_LAB="yes"
# autentication is disabled for now
ENV NOTEBOOK_TOKEN=""
ENV NOTEBOOK_BASE_DIR="$HOME/work"

ENV DAKOTA_VERSION 6.16.0
USER root

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  ffmpeg \
  make \
  dvipng \
  gosu \
  octave \
  gnuplot \
  liboctave-dev \
  bc \
  ghostscript \
  texlive-xetex \
  texlive-fonts-recommended \
  texlive-latex-recommended \
  texlive-fonts-extra \
  zip \
  fonts-freefont-otf \
  libboost-all-dev \
  libblas-dev \
  liblapack-dev \
  libopenmpi-dev \
  openmpi-bin \
  gsl-bin \
  libgsl-dev \
  perl \
  libhdf5-dev \
  gfortran && \
  apt-get clean && rm -rf /var/lib/apt/lists/*   

RUN pip --no-cache --quiet install --upgrade \
  pip \
  setuptools \
  wheel

# Service (dakota) specific installation
# --------------------------------------------------------------------

FROM base as build

ENV SC_BUILD_TARGET build

WORKDIR /build

# defines the output of the build
RUN mkdir --parents /build/bin

# Dependencies for compilation
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  gcc \
  cmake

# Download dakota tar

ENV INSTALL_DIR /build/bin/dakota

RUN wget https://dakota.sandia.gov/sites/default/files/distributions/public/dakota-${DAKOTA_VERSION}-public-src-cli.tar.gz && \
  tar -xzvf dakota-${DAKOTA_VERSION}-public-src-cli.tar.gz && \
  rm -rf dakota-${DAKOTA_VERSION}-public-src-cli.tar.gz

# Compile and install dakota, add it to PATH
RUN cmake -D CMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
  -D CMAKE_C_FLAGS="-O2" -D CMAKE_CXX_FLAGS="-O2"  \
  -D CMAKE_Fortran_FLAGS="-O2" \ 
  -D DAKOTA_HAVE_GSL:BOOL=TRUE \ 
  -D HAVE_QUESO:BOOL=TRUE \ 
  -D DAKOTA_HAVE_MPI:BOOL=TRUE \ 
  -D DAKOTA_HDF5:BOOL=TRUE \
  -D Boost_NO_BOOST_CMAKE:BOOL=TRUE \
  dakota-6.16.0-public-src-cli && \
  make -j 4 && \
  make install && \
  rm -r dakota-6.16.0-public-src-cli

# Python kernels and Jupyter
# --------------------------------------------------------------------

FROM base as production

ENV HOME="/home/$NB_USER"

USER root

WORKDIR ${HOME}

# Install kernel in virtual-env

RUN python3 -m venv .venv &&\
  .venv/bin/pip --no-cache --quiet install --upgrade pip~=21.3 wheel setuptools &&\
  .venv/bin/pip --no-cache --quiet install ipykernel &&\
  .venv/bin/python -m ipykernel install \
  --user \
  --name "python-maths" \
  --display-name "python (maths)" \
  && \
  echo y | .venv/bin/python -m jupyter kernelspec uninstall python3 &&\
  .venv/bin/python -m jupyter kernelspec list

# copy and resolve dependecies to be up to date
COPY --chown=$NB_UID:$NB_GID kernels/python-maths/requirements.in ${NOTEBOOK_BASE_DIR}/requirements.in
RUN .venv/bin/pip --no-cache install pip-tools && \
  .venv/bin/pip-compile --build-isolation --output-file ${NOTEBOOK_BASE_DIR}/requirements.txt ${NOTEBOOK_BASE_DIR}/requirements.in  && \
  .venv/bin/pip --no-cache install -r ${NOTEBOOK_BASE_DIR}/requirements.txt && \
  rm ${NOTEBOOK_BASE_DIR}/requirements.in
RUN jupyter serverextension enable voila && \
  jupyter server extension enable voila

# Copy dakota executables
COPY --from=build /build/bin/dakota dakota

RUN echo "export PATH=${HOME}/dakota/bin:${HOME}/dakota/share/dakota/test:${PATH}" >> ~/.bashrc

# Import matplotlib the first time to build the font cache.
ENV XDG_CACHE_HOME /home/$NB_USER/.cache/
RUN MPLBACKEND=Agg .venv/bin/python -c "import matplotlib.pyplot" && \
  # run fix permissions only once
  fix-permissions /home/$NB_USER

# copy README and CHANGELOG
COPY --chown=$NB_UID:$NB_GID CHANGELOG.md ${NOTEBOOK_BASE_DIR}/CHANGELOG.md
COPY --chown=$NB_UID:$NB_GID README.ipynb ${NOTEBOOK_BASE_DIR}/README.ipynb
# remove write permissions from files which are not supposed to be edited
RUN chmod gu-w ${NOTEBOOK_BASE_DIR}/CHANGELOG.md && \
  chmod gu-w ${NOTEBOOK_BASE_DIR}/requirements.txt

RUN mkdir --parents "/home/${NB_USER}/.virtual_documents" && \
  chown --recursive "$NB_USER" "/home/${NB_USER}/.virtual_documents"
ENV JP_LSP_VIRTUAL_DIR="/home/${NB_USER}/.virtual_documents"

WORKDIR ${HOME}/test_dakota

# Test dakota
ENV PATH=${HOME}/dakota/bin:${HOME}/dakota/share/dakota/test:${HOME}/dakota/gui:${PATH}
RUN cp ${HOME}/dakota/share/dakota/examples/users/rosen_multidim.in ${HOME}/test_dakota && \
    cd ${HOME}/test_dakota && \
    dakota -v && \
    dakota -i rosen_multidim.in -o rosen_multidim.out > rosen_multidim.stdout

# Copying boot scripts
COPY --chown=$NB_UID:$NB_GID docker /docker

# Check that dakota works within the python venv
RUN echo 'export PATH="/home/${NB_USER}/.venv/bin:$PATH"' >> "/home/${NB_USER}/.bashrc" && \
    echo 'PYTHONPATH=$PYTHONPATH:${HOME}/dakota/share/dakota/Python/' >> "/home/${NB_USER}/.bashrc" && \
    cp -r ${HOME}/dakota/share/dakota/examples/official/gui/analysis_driver_tutorial/complete_python_driver/ ${HOME}/test_dakota/complete_python_driver && \
    cd ${HOME}/test_dakota/complete_python_driver && \
    dakota -i CPS.in -o python-driver.out > python-driver.stdout    

WORKDIR ${HOME}

EXPOSE 8888

ENTRYPOINT [ "/bin/bash", "/docker/entrypoint.bash" ]