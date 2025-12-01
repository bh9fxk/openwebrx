#!/usr/bin/env bash
#
BUILD_PACKAGES="libprotobuf-dev protobuf-compiler libcodecserver-dev"

echo "------安装依赖------"
apt-get -qq update
apt-get -qq -y install --no-install-recommends wget gpg git debhelper cmake
apt-get -qq -y install --no-install-recommends $BUILD_PACKAGES

cd /tmp
# install mbelib
echo "------install mbelib------"
git clone https://github.com/szechyjs/mbelib.git
cd mbelib
dpkg-buildpackage
cd ..
rm -rf mbelib
dpkg -i libmbe1_1.3.0_*.deb libmbe-dev_1.3.0_*.deb
rm *.deb

# install codecserver-softmbe
echo "------install codecserver-softmbe------"
git clone https://github.com/knatterfunker/codecserver-softmbe.git
cd codecserver-softmbe
# ignore missing library linking error in dpkg-buildpackage command
sed -i 's/dh \$@/dh \$@ --dpkg-shlibdeps-params=--ignore-missing-info/' debian/rules
dpkg-buildpackage
cd ..
rm -rf codecserver-softmbe
dpkg -i codecserver-driver-softmbe_0.0.1_*.deb
rm *.deb

# link the library to the correct location for the codec server
echo "---link the library to the correct location for the codec server---"
#ln -s /usr/lib/x86_64-linux-gnu/codecserver/libsoftmbe.so /usr/local/lib/codecserver/
linklib=$(dpkg -L codecserver-driver-softmbe | grep libsoftmbe.so)
ln -s $linklib /usr/local/lib/codecserver/

# add the softmbe library to the codecserver config
echo "---add the softmbe library to the codecserver config---"
mkdir -p /usr/local/etc/codecserver
cat >> /usr/local/etc/codecserver/codecserver.conf << _EOF_
[device:softmbe]
driver=softmbe
_EOF_

echo "------清理------"
apt-get -qq update
apt-get -qq -y purge --autoremove --allow-remove-essential $BUILD_PACKAGES
apt-get -qq -y purge --autoremove --allow-remove-essential wget gpg git debhelper cmake
apt-get -y autoremove
apt-get autoclean

rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*
