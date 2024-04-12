#!/bin/bash
source ./venv/bin/activate

uwsgi --ini /var/lib/uwsgi/uwsgi.conf
