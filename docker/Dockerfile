FROM lmscommunity/lyrionmusicserver:stable

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/lms-ytm-entrypoint
RUN chmod +x /usr/local/bin/lms-ytm-entrypoint

ENTRYPOINT ["lms-ytm-entrypoint"]
