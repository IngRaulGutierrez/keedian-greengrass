FROM amazoncorretto:11-al2023

# Instalar Python 3.11 (AL2023 incluye Python 3.9 por defecto; los componentes
# keedian-link usan la sintaxis `str | None` que requiere Python 3.10+)
RUN dnf install -y \
    python3.11 \
    unzip \
    sudo \
    shadow-utils \
    && dnf clean all \
    && ln -sf /usr/bin/python3.11 /usr/bin/python3 \
    && python3 -m ensurepip --upgrade

# Instalar SDK de Greengrass IPC y dependencias de los componentes keedian-link
RUN python3 -m pip install --upgrade pip --quiet \
    && python3 -m pip install --quiet \
    awsiotsdk \
    structlog \
    pydantic \
    pyyaml \
    "sqlalchemy[asyncio]" \
    aiosqlite \
    aiomysql \
    pymodbus \
    tenacity \
    psutil \
    python-dateutil \
    APScheduler \
    httpx \
    zstandard \
    "BAC0>=2024.9.8"

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
