# A build slow enough that the second, cached one shows.
FROM alpine:3.20
RUN sleep 20 && echo "built once" > /built
RUN cat /built
