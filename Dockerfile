FROM maven:3.9.11-eclipse-temurin-21 AS plugin-builder

ARG GEOSPARQL_V2_REPOSITORY=https://github.com/Kurrawong/graphdb-geosparql-plugin.git
ARG GEOSPARQL_V2_REF=master

WORKDIR /build/graphdb-geosparql-plugin

RUN git init \
    && git remote add origin "${GEOSPARQL_V2_REPOSITORY}" \
    && git fetch --depth 1 origin "${GEOSPARQL_V2_REF}" \
    && git checkout --detach FETCH_HEAD \
    && git rev-parse HEAD > /build/geosparql-v2-commit.txt

RUN mvn --batch-mode clean package \
    && mkdir -p target/docker-plugin \
    && cd target/docker-plugin \
    && jar xf ../geosparql-plugin-graphdb-plugin.zip

FROM ontotext/graphdb:11.4.0

USER root

RUN rm -rf \
    /opt/graphdb/dist/lib/plugins/geosparql-plugin \
    /opt/graphdb/dist/lib/plugins/graphdb-geosparql-plugin

COPY --from=plugin-builder \
    /build/graphdb-geosparql-plugin/target/docker-plugin/geosparql-plugin \
    /opt/graphdb/dist/lib/plugins/geosparql-plugin

COPY --from=plugin-builder \
    /build/geosparql-v2-commit.txt \
    /opt/graphdb/geosparql-v2-source-commit.txt
