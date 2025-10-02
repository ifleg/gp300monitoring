FROM rootproject/root:latest

RUN mkdir -p /opt/grandlib
# Add package for C compilation 
RUN apt-get update\
&& apt-get install -y \
    git \
    make \
    libpng-dev \
    graphviz \
    python3-pip \
    python3-venv \
    vim \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /opt/grandlib/requirements_grandlib.txt
RUN python3 -m venv /opt/grandlib/venv \
&& /opt/grandlib/venv/bin/pip3 install --no-cache-dir -r /opt/grandlib/requirements_grandlib.txt

# init env docker
WORKDIR /home
ENV PATH="/opt/grandlib/venv/bin:.:${PATH}"
ENTRYPOINT ["/bin/bash"]
SHELL ["/bin/bash", "-c"]
