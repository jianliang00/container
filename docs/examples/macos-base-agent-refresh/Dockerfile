ARG BASE_REF=ghcr.io/jianliang00/macos-base:26.3
FROM --platform=darwin/arm64 ${BASE_REF}

COPY container-macos-guest-agent /usr/local/bin/container-macos-guest-agent

RUN /bin/chmod 0755 /usr/local/bin/container-macos-guest-agent \
 && /usr/bin/grep -a "networkConfigure" /usr/local/bin/container-macos-guest-agent >/dev/null
