FROM alpine:3

COPY 10-demystifying.conf /cni/10-demystifying.conf
COPY demystifying /cni/demystifying
COPY entrypoint.sh /cni/entrypoint.sh
RUN chmod +x /cni/demystifying
RUN chmod +x /cni/entrypoint.sh

ENTRYPOINT ["/cni/entrypoint.sh"]
