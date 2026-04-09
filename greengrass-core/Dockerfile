FROM amazoncorretto:11-al2023

# Instalar dependencias del sistema
RUN dnf install -y \
    python3 \
    python3-pip \
    unzip \
    sudo \
    shadow-utils \
    && dnf clean all

# Instalar SDK de Greengrass IPC para Python
RUN pip3 install awsiotsdk

# Descargar e instalar el Nucleus de Greengrass
RUN curl -s https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip \
    -o /tmp/greengrass-nucleus-latest.zip \
    && unzip /tmp/greengrass-nucleus-latest.zip -d /tmp/GreengrassInstaller \
    && rm /tmp/greengrass-nucleus-latest.zip

# Crear usuario y grupo para Greengrass
RUN groupadd --system ggc_group && \
    useradd --system --gid ggc_group ggc_user

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
