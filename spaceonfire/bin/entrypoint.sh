#!/bin/bash

# Set custom webroot
if [ -n "$WEBROOT" ]; then
	sed -i "s#root /var/www/html;#root ${WEBROOT};#g" /etc/nginx/sites-available/default.conf
else
	WEBROOT=/var/www/html
fi

# Recreate nginx user with passed UID and GID
if [ -n "$PUID" ]; then
	if [ -z "$PGID" ]; then
		PGID=${PUID}
	fi
	deluser nginx
	addgroup -g ${PGID} nginx
	adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx -u ${PUID} nginx
	# Fix permissions on nginx library dir. See #37
	chown nginx.nginx /var/lib/nginx
	chown -R nginx.nginx /var/lib/nginx/tmp
fi

# Setup access rights for nginx group
{
	setfacl -RLm g:nginx:rwx "$COMPOSER_HOME"
	setfacl -RLdm g:nginx:rwx "$COMPOSER_HOME"
	setfacl -RLm g:nginx:rwx /opt/spaceonfire/composer/v1
	setfacl -RLdm g:nginx:rwx /opt/spaceonfire/composer/v1
	setfacl -RLm g:nginx:rwx /opt/spaceonfire/composer/v2
	setfacl -RLdm g:nginx:rwx /opt/spaceonfire/composer/v2
} >>/dev/null 2>&1

if [[ "$SKIP_SETFACL" != "1" ]]; then
	setfacl -RLdm g:nginx:rwx /var/www/html/ >>/dev/null 2>&1
fi

# Copy default index.html
if [ $(ls $WEBROOT/index.{php,htm,html} 2>/dev/null | wc -l) -eq 0 ]; then
	cp -f /opt/spaceonfire/html/index.html $WEBROOT
fi

if [ -n "$SOF_PRESET" ]; then
	/opt/spaceonfire/bin/select-preset.sh $SOF_PRESET
fi

if [ -n "$COMPOSER_VERSION" ]; then
	/opt/spaceonfire/bin/select-composer.sh $COMPOSER_VERSION
fi

/opt/spaceonfire/bin/ssmtp-setup.php

# Set Nginx read timeout
if [[ -z "$NGINX_READ_TIMEOUT" ]] && [[ "$APPLICATION_ENV" != "production" ]]; then
	NGINX_READ_TIMEOUT=9999
fi

if [[ -n "$NGINX_READ_TIMEOUT" ]]; then
	FastCgiParamsFile="/etc/nginx/fastcgi_params"
	if ! grep -q fastcgi_read_timeout "$FastCgiParamsFile"; then
		{
			echo ""
			echo "fastcgi_read_timeout $NGINX_READ_TIMEOUT;"
		} >>$FastCgiParamsFile
	fi
fi

# Prevent config files from being filled to infinity by force of stop and restart the container
lastlinephpconf="$(grep "." /usr/local/etc/php-fpm.conf | tail -1)"
if [[ $lastlinephpconf == *"php_flag[display_errors]"* ]]; then
	sed -i '$ d' /usr/local/etc/php-fpm.conf
fi

# Display PHP error's or not
if [[ "$ERRORS" != "1" ]]; then
	echo "php_flag[display_errors] = off" >>/usr/local/etc/php-fpm.conf
else
	echo "php_flag[display_errors] = on" >>/usr/local/etc/php-fpm.conf
fi

# Display Version Details or not
if [[ "$HIDE_NGINX_HEADERS" == "0" ]]; then
	sed -i "s/server_tokens off;/server_tokens on;/g" /etc/nginx/nginx.conf
else
	sed -i "s/expose_php = On/expose_php = Off/g" /usr/local/etc/php-fpm.conf
fi

# Pass real-ip to logs when behind ELB, etc
if [[ "$REAL_IP_HEADER" == "1" ]]; then
	vhosts=('/etc/nginx/sites-available/default.conf' '/etc/nginx/sites-available/default-ssl.conf')
	for vhost in vhosts; do
		sed -i "s/#real_ip_header X-Forwarded-For;/real_ip_header X-Forwarded-For;/" $vhost
		sed -i "s/#set_real_ip_from/set_real_ip_from/" $vhost
		if [ -n "$REAL_IP_FROM" ]; then
			sed -i "s#172.16.0.0/12#$REAL_IP_FROM#" $vhost
		fi
	done
fi

#Display errors in docker logs
if [ -n "$PHP_ERRORS_STDERR" ]; then
	echo "log_errors = On" >>/usr/local/etc/php/conf.d/docker-vars.ini
	echo "error_log = /dev/stderr" >>/usr/local/etc/php/conf.d/docker-vars.ini
fi

# Increase the memory_limit
if [ -n "$PHP_MEM_LIMIT" ]; then
	sed -i "s/memory_limit = 128M/memory_limit = ${PHP_MEM_LIMIT}M/g" /usr/local/etc/php/conf.d/docker-vars.ini
fi

# Increase the post_max_size
if [ -n "$PHP_POST_MAX_SIZE" ]; then
	sed -i "s/post_max_size = 100M/post_max_size = ${PHP_POST_MAX_SIZE}M/g" /usr/local/etc/php/conf.d/docker-vars.ini
fi

# Increase the upload_max_filesize
if [ -n "$PHP_UPLOAD_MAX_FILESIZE" ]; then
	sed -i "s/upload_max_filesize = 100M/upload_max_filesize= ${PHP_UPLOAD_MAX_FILESIZE}M/g" /usr/local/etc/php/conf.d/docker-vars.ini
fi

# Enable xdebug only
if [ "$APPLICATION_ENV" != "production" ]; then
	XdebugFile='/usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini'
	if [[ "$ENABLE_XDEBUG" == "1" ]]; then
		if [ -f $XdebugFile ]; then
			echo "Xdebug enabled"
		else
			echo "Enabling xdebug"
			# echo "If you get this error, you can safely ignore it: /usr/local/bin/docker-php-ext-enable: line 83: nm: not found"
			# see https://github.com/docker-library/php/pull/420
			docker-php-ext-enable xdebug
			# see if file exists
			if [ -f $XdebugFile ]; then
				# Get default route ip if not set
				if [ -z "$XDEBUG_REMOTE_HOST" ]; then
					XDEBUG_REMOTE_HOST=$(ip route | awk '/default/ { print $3 }')
				fi

				# See if file contains xdebug text.
				if grep -q xdebug.remote_enable "$XdebugFile"; then
					echo "Xdebug already enabled... skipping"
				else
					{
						echo "zend_extension=$(find /usr/local/lib/php/extensions/ -name xdebug.so)"
						echo "xdebug.mode=debug"
						echo "xdebug.start_with_request=1"
						echo "xdebug.idekey=${XDEBUG_IDEKEY:-docker}"
						echo "xdebug.client_host=${XDEBUG_REMOTE_HOST}"
						echo "xdebug.var_display_max_depth=-1"
						echo "xdebug.var_display_max_children=-1"
						echo "xdebug.var_display_max_data=-1"
					} >$XdebugFile
				fi
			fi
		fi
	else
		if [ -f $XdebugFile ]; then
			echo "Disabling Xdebug"
			rm $XdebugFile
		fi
	fi
fi

# Run custom scripts
if [[ "$RUN_SCRIPTS" == "1" ]]; then
	if [ -d "/var/www/html/scripts/" ]; then
		# make scripts executable in case they aren't
		chmod -Rf 750 /var/www/html/scripts/*
		sync
		# run scripts in number order
		for i in /var/www/html/scripts/*; do $i; done
	else
		echo "Can't find script directory"
	fi
fi

# Start supervisord and services
exec /usr/bin/supervisord -n -c /etc/supervisord.conf
