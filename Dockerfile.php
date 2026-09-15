# Dockerfile para API PHP 8.2 Production (Hardened)
FROM php:8.2-fpm-alpine

# Instalar dependências do sistema e extensões PHP necessárias
RUN apk add --no-cache \
    postgresql-dev \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    oniguruma-dev \
    libxml2-dev \
    icu-dev \
    git \
    curl \
    && docker-php-ext-install \
    pdo_pgsql \
    pgsql \
    gd \
    mbstring \
    intl \
    xml \
    bcmath \
    opcache \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && rm -rf /var/cache/apk/*

# Configurar OPcache para Produção
RUN { \
    echo 'opcache.enable=1'; \
    echo 'opcache.memory_consumption=256'; \
    echo 'opcache.max_accelerated_files=20000'; \
    echo 'opcache.revalidate_freq=60'; \
    echo 'opcache.validate_timestamps=0'; # Crítico: desliga checagem de arquivo em prod para performance \
    echo 'opcache.save_comments=1'; \
} > /usr/local/etc/php/conf.d/opcache-recommended.ini

# Configurações de Segurança PHP (Hardening)
RUN { \
    echo 'expose_php = Off'; # Esconde versão do PHP \
    echo 'display_errors = Off'; # Nunca mostrar erros em prod \
    echo 'log_errors = On'; \
    echo 'error_log = /dev/stderr'; \
    echo 'max_execution_time = 30'; \
    echo 'upload_max_filesize = 10M'; \
    echo 'post_max_size = 10M'; \
    echo 'disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source'; \
} > /usr/local/etc/php/conf.d/security-hardening.ini

# Criar usuário não-root para rodar o processo (Segurança)
RUN addgroup -g 1000 appgroup && adduser -u 1000 -G appgroup -s /bin/sh -D appuser

WORKDIR /var/www/html

# Copiar código da aplicação
COPY --chown=appuser:appgroup api/ ./api/
COPY --chown=appuser:appgroup shared/ ./shared/

# Permissões restritas
RUN chown -R appuser:appgroup /var/www/html \
    && chmod -R 750 /var/www/html

USER appuser

EXPOSE 9000

CMD ["php-fpm"]
