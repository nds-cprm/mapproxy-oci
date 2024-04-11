#!/bin/bash
source ./venv/bin/activate

uwsgi --ini ./uwsgi.conf
