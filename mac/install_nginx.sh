!/usr/bin/env bash

brew install nginx



# The default port has been set in /usr/local/etc/nginx/nginx.conf to 8080 so that nginx can run without sudo.

# nginx will load all files in /usr/local/etc/nginx/servers/.

# To start nginx now and restart at login:
#  brew services start nginx
# Or, if you don't want/need a background service you can just run:
#  /usr/local/opt/nginx/bin/nginx -g daemon\ off\;


# https://gist.github.com/kevmo/236098a460773c99e373cb2e1f325b99

mv /usr/local/etc/nginx/nginx.conf /usr/local/etc/nginx/nginx.conf.bak && cp /usr/local/etc/nginx/nginx.conf.bak /usr/local/etc/nginx/nginx.conf

mkdir -p /var/www/html

# copy init config
cp -r ../etc/nginx/ /usr/local/etc/nginx/

brew services start nginx
