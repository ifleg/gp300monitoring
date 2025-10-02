#! /bin/bash
#
docker rmi grandlib_base
docker build -f base.dockerfile . --tag=grandlib_base
