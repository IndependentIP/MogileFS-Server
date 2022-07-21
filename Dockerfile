FROM debian:buster

RUN apt-get update && apt-get update
RUN apt-get install -y vim && \
    apt-get install -y debhelper && \
    apt-get install perl && \
    apt-get install libstring-crc32-perl && \
    apt-get install dpkg && \
    apt-get install dpkg-dev && \
    apt-get install -y sysstat && \
    apt-get install fakeroot

RUN apt-get install -y libbsd-resource-perl && \
    apt-get install -y libdanga-socket-perl && \
    apt-get install -y libnet-netmask-perl && \
    apt-get install -y libsys-syscall-perl && \
    apt-get install -y libperlbal-perl && \
    apt-get install -y libio-aio-perl && \
    apt-get install -y libio-stringy-perl && \
    apt-get install -y libwww-perl && \
    apt-get install -y libdbd-mysql-perl && \
    apt-get install -y libdbi-perl  

WORKDIR /mogilefs

ADD . /mogilefs

RUN dpkg-buildpackage -rfakeroot


