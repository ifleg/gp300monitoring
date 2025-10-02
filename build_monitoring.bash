#!/bin/bash

docker rmi grandlib_monitoring
./build_base.bash
docker build -f ./monitoring.dockerfile . --tag=grandlib_monitoring
