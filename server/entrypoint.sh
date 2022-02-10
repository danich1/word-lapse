#!/bin/bash

function dir_is_empty {
    [ -n "$(find "$1" -maxdepth 0 -type d -empty 2>/dev/null)" ]
}

# enable reloading if DEBUG is 1
[[ ${DEBUG:-0} -eq 1 ]] && DO_RELOAD="--reload" || DO_RELOAD=""

# enable inline redis (i.e., as a forked process), if USE_INLINE_REDIS is 1
if [ ${USE_INLINE_REDIS:-0} -eq 1 ]; then
    # fork off a redis process and override REDIS_URL to use this local one
    redis-server /redis/redis.conf --save 60 1 --loglevel warning &
    export REDIS_URL="redis://localhost:6379"
fi

# time before gunicorn decides a worker is "dead"
GUNICORN_TIMEOUT=${GUNICORN_TIMEOUT:-600}

# if /app/data is populated, attempt a git lfs pull
# if it's not, clone word-lapse-models into it and then pull
if [ "${UPDATE_DATA:-1}" = "1" ]; then
    DATA_DIR=/app/data/

    # squelch hostname checks about github.com
    mkdir -p ~/.ssh && ssh-keyscan -t rsa github.com > ~/.ssh/known_hosts

    # ensure DATA_DIR exists
    mkdir -p "${DATA_DIR}"

    if dir_is_empty "${DATA_DIR}"; then
        # the folder is empty
        # clone submodule into ./data and do an lfs pull
        echo "* ${DATA_DIR} is empty, cloning data into it"
        git clone 'https://github.com/greenelab/word-lapse-models.git' "${DATA_DIR}"
        cd "${DATA_DIR}" && git pull --ff-only
    else
        # just attempt to pull new data into the existing folder
        echo "* ${DATA_DIR} is *not* empty, refreshing contents"
        cd "${DATA_DIR}" && git pull --ff-only
    fi
fi

if [ "${USE_HTTPS:-1}" = "1" ]; then
    # check if our certificate needs to be created (e.g., if it's missing)
    # or if we just need to renew
    if dir_is_empty /etc/letsencrypt/; then
        certbot certonly \
            --non-interactive --standalone --agree-tos \
            -m "${ADMIN_EMAIL:-faisal.alquaddoomi@cuanschutz.edu}" \
            -d "${DNS_NAME:-api-wl.greenelab.com}"
    else
        # most of the time this is a no-op, since it won't renew if it's not near expiring
        certbot renew
    fi

    # finally, run the server (with HTTPS)
    cd /app

    if [[ ${USE_UVICORN:-0} -eq 1 ]]; then
        /usr/local/bin/uvicorn backend.main:app --host 0.0.0.0 --port 443 ${DO_RELOAD} \
            --ssl-keyfile=/etc/letsencrypt/live/api-wl.greenelab.com/privkey.pem \
            --ssl-certfile=/etc/letsencrypt/live/api-wl.greenelab.com/fullchain.pem
    else
        gunicorn backend.main:app --bind 0.0.0.0:443 ${DO_RELOAD} \
            --timeout ${GUNICORN_TIMEOUT} \
            --workers ${WEB_CONCURRENCY:-4} --worker-class uvicorn.workers.UvicornWorker \
            --keyfile=/etc/letsencrypt/live/api-wl.greenelab.com/privkey.pem \
            --certfile=/etc/letsencrypt/live/api-wl.greenelab.com/fullchain.pem
    fi
else
    # finally, run the server (with just HTTP)
    cd /app

    if [[ ${USE_UVICORN:-0} -eq 1 ]]; then
        /usr/local/bin/uvicorn backend.main:app --host 0.0.0.0 --port 80 ${DO_RELOAD}
    else
        gunicorn backend.main:app --bind 0.0.0.0:80 ${DO_RELOAD} \
            --timeout ${GUNICORN_TIMEOUT} \
            --workers ${WEB_CONCURRENCY:-4} --worker-class uvicorn.workers.UvicornWorker 
    fi
fi
