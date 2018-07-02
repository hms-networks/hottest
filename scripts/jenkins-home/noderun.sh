#!/bin/bash -x

# Copyright (C) 2018 HMS Industrial Networks AB
#
# This program is the property of HMS Industrial Networks AB.
# It may not be reproduced, distributed, or used without permission
# of an authorized company official.

# Runs a dummy Jenkins slave on localhost. This is to be called by Jenkis
# itself.

rm -rf agent.jar*
wget -q $SLAVEJAR_URL
java -jar agent.jar
