FROM grandlib_base

RUN ln -s /usr/include/vdt /opt/root/include/vdt
RUN mkdir -p /opt/grandlib/softs
COPY softs /opt/grandlib/softs
WORKDIR /opt/grandlib/softs/grand
RUN env/setup.sh
ENV PYTHONPATH="/opt/grandlib/softs/grand:${PYTHONPATH}"

WORKDIR /opt/grandlib/softs/gtot
RUN mkdir cmake-build-release
WORKDIR /opt/grandlib/softs/gtot/cmake-build-release
RUN cmake  .. && make all


ENV PATH="${PATH}:/opt/grandlib/softs/gtot/cmake-build-release"
ENV LD_LIBRARY_PATH="/opt/grandlib/softs/gtot/cmake-build-release:${LD_LIBRARY_PATH}"
WORKDIR /home
#ENTRYPOINT ["/bin/bash"]
#SHELL ["/bin/bash", "-c"]
ENTRYPOINT []
CMD ["/bin/bash", "-c", "tail -f /dev/null"]



