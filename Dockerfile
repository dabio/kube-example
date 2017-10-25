FROM scratch
COPY server /
ENTRYPOINT ["/server"]
EXPOSE 8080
