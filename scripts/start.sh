#!/bin/bash
source ./venv/bin/activate

exec uwsgi --ini /var/lib/uwsgi/uwsgi.conf
