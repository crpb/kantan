#!/bin/bash
# Filename:      netscript.sh
# Purpose:       automatically deploy FAI server using Grml and its netscript bootoption
# Authors:       (c) Michael Prokop <mika@grml.org>
################################################################################

# Execute "the real script" with its standard output going to
# both stdout and netscript.sh.log, with its standard error going to
# both stderr and netscript.sh.errors, and with errorlevel passing.
#myname=$0
#rm -f "$myname".rc
#( (
#exec >&3
#trap "x=\$?; echo \$x >'$myname'.rc; exit \$x" EXIT

################################################################################
# the real script

# helper stuff {{{
set -e

HOST=$(hostname)

log() {
  printf "Info: $*\n"
}

error() {
  printf "Error: $*\n"
}
# }}}

# main execution functions {{{
get_fai_config() {
   . /etc/grml/autoconfig.functions
   CONFIG="$(getbootparam 'netscript' 2>/dev/null)"
   FAI_CONF="${CONFIG%%netscript.sh}fai.conf"
   if [ -n "$FAI_CONF" ] ; then
     cd /tmp
     wget -O fai.conf $FAI_CONF
   else
     printf "Error retrieving FAI configuration. :(\n" >&2
     exit 1
   fi

   . fai.conf
}

software_install() {
  if [ -z "$FAI_MIRROR" ] ; then
    log "Configuration \$FAI_MIRROR unset, skipping sources.list step."
  else
    log "Adjusting /etc/apt/sources.list.d/fai.list"
    if ! grep -q "$FAI_MIRROR" /etc/apt/sources.list.d/fai.list &>/dev/null ; then
      echo "$FAI_MIRROR" >> /etc/apt/sources.list.d/fai.list
    fi
  fi

  log "Installing software"
  apt-get update
  APT_LISTCHANGES_FRONTEND=none APT_LISTBUGS_FRONTEND=none \
    DEBIAN_FRONTEND=noninteractive apt-get -y --force-yes \
    --no-install-recommends install \
    fai-client fai-doc fai-quickstart fai-server fai-setup-storage \
    isc-dhcp-server portmap nfs-kernel-server tftpd-hpa \
    imvirt dnsmasq

  # dhcp3-server -> /etc/dhcp3 vs. /etc/dhcp
}

prechecks() {
  # this is WFM, but makes sure the script is executed under KVM only
  if [[ "$(imvirt)" == "KVM" ]] ; then
    log "Running inside KVM, will continue..."
  else
    error "Not running inside KVM as expected, will not continue."
    exit 1
  fi
}

dhcpd_conf() {
  log "Adjusting dhcpd configuration"
  if ! grep -q '^# FAI deployment script' /etc/dhcp/dhcpd.conf ; then
    cat >> /etc/dhcp/dhcpd.conf << EOF
# FAI deployment script
subnet 192.168.10.0 netmask 255.255.255.0 {
  range 192.168.10.50 192.168.10.200;
  option routers 192.168.10.1;
  option domain-name-servers 192.168.10.1;
  next-server 192.168.10.1;
  filename "pxelinux.0";
}
EOF
  fi

  if ! grep -q "^# FAI deployment script - ${DEMOHOST}" /etc/dhcp/dhcpd.conf ; then
    cat >> /etc/dhcp/dhcpd.conf << EOF
# FAI deployment script - ${DEMOHOST}
host ${DEMOHOST} {hardware ethernet 00:1d:92:ab:3f:80;fixed-address ${DEMOHOST};}
EOF
  fi

  if [ -r /etc/default/isc-dhcp-server ] ; then
    sed -i 's/INTERFACES=.*/INTERFACES="eth1"/' /etc/default/isc-dhcp-server
  fi
}

tftpd_conf() {
  log "Adjusting tftpd configuration"

  if grep -q '^# FAI deployment script' /etc/default/tftpd-hpa ; then
    return 0
  fi

  # newer tftpd-hpa
  if grep -q 'TFTP_DIRECTORY' /etc/default/tftpd-hpa ; then
    cat > /etc/default/tftpd-hpa << EOF
# FAI deployment script
TFTP_DIRECTORY='/srv/tftp/fai'
TFTP_ADDRESS="0.0.0.0:69"
TFTP_USERNAME="tftp"
RUN_DAEMON="yes"
TFTP_OPTIONS="--secure"
EOF

  else # older tftpd-hpa
    cat > /etc/default/tftpd-hpa << EOF
# FAI deployment script
RUN_DAEMON="yes"
OPTIONS="-l -s /srv/tftp/fai"
EOF
  fi
}

network_conf() {
  log "Adjusting network configuration"
  if ! grep -q '^# FAI deployment script' /etc/network/interfaces ; then
  cat > /etc/network/interfaces << EOF
# FAI deployment script
iface lo inet loopback
auto lo

auto eth1
iface eth1 inet static
  address 192.168.10.1
  netmask 255.255.255.0
# gateway 192.168.10.1
EOF
  fi

  # kill -9 $(pidof pump &>/dev/null) $(pidof dhclient &>/dev/null) 2>/dev/null || true
  /etc/init.d/networking restart

  echo 1 > /proc/sys/net/ipv4/ip_forward
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

}

hosts_conf() {
  log "Adjusting /etc/hosts"
  if ! grep -q '^# FAI deployment script' /etc/hosts ; then
    cat >> /etc/hosts << EOF
# FAI deployment script
192.168.10.1  ${HOST}
192.168.10.50 ${DEMOHOST}
EOF
  fi
}

fai_conf() {
  log "Adjusting FAI configuration"

  sed -i "s;FAI_DEBOOTSTRAP=.*;FAI_DEBOOTSTRAP=\"lenny http://${DEBIAN_MIRROR}/debian\";" \
      /etc/fai/make-fai-nfsroot.conf
  sed -i "s/cdn.debian.net/${DEBIAN_MIRROR}/" /etc/fai/apt/sources.list

  # make sure new FAI version is available inside nfsroot as well
  if ! grep -q '^# FAI deployment script' /etc/fai/apt/sources.list ; then
    cat >> /etc/fai/apt/sources.list << EOF
# FAI deployment script
$FAI_MIRROR
EOF
  fi

  if ! grep -q '^# FAI deployment script' /etc/fai/fai.conf ; then
    cat >> /etc/fai/fai.conf << EOF
# FAI deployment script
FAI_CONFIG_SRC="nfs://$HOST/srv/fai/config"
EOF
  fi
}

nfs_setup() {
  # fai-setup rebuilds nfsroot each time, we want
  # to be able to skip that and just export /srv/* via nfs
  # if  we have a nfsroot already we want to reuse, see #600195
  if ! grep -q '^/srv' /etc/exports ; then
    cat >> /etc/exports << EOF
# FAI deployment script
/srv/fai/config 192.168.10.1/24(async,ro,no_subtree_check)
/srv/fai/nfsroot 192.168.10.1/24(async,ro,no_subtree_check,no_root_squash)
EOF
    /etc/init.d/nfs-kernel-server restart
  fi
}

disk_setup() {

  if [ -r /srv/fai_netscript_done ] ; then
    if grep -q 'fai_rebuild' /proc/cmdline ; then
      log "Rebuilding /srv on $DISK as requested via fai_rebuild bootoption."
      umount /srv
    else
      log "Disk $DISK present already on /srv, skipping disk setup."
      return 0
    fi
  fi

  # existing installation present? re-use it
  # just rm -rf /srv to force re-installation of FAI
  if mount /dev/${DISK}1 /srv ; then
    log "Existing partition found, trying to re-use."

    if ! [ -r /srv/fai_netscript_done ] ; then
      log "No /srv/fai_netscript_done found, will continue to formating disk."
      umount /srv
    else

      if grep -q 'fai_rebuild' /proc/cmdline ; then
        log "Rebuilding /srv on $DISK as requested via fai_rebuild bootoption."
	umount /srv
      else
        log "/srv/fai_netscript_done present on $DISK - skipping disk setup."
        return 0
      fi

    fi
  fi

  log "Formating disk $DISK:"
  # this is another WFM, but makes sure I format just disks inside QEMU :)
  if ! grep -q 'QEMU HARDDISK' /sys/block/${DISK}/device/model ; then
    error "Disk $DISK does not look as expected (QEMU HARDDISK)."
    exit 1
  else
    export LOGDIR=/tmp/setup-storage
    [ -d "$LOGDIR" ] || mkdir -p $LOGDIR
    export disklist=$(/usr/lib/fai/disk-info | sort)

    cat << EOT | setup-storage -X -f -
disk_config $DISK
primary - 100% ext3 rw
EOT
  fi

  mv /srv /srv.old
  mkdir /srv
  mount /dev/${DISK}1 /srv
  mv /srv.old/* /srv/ || true
  rmdir /srv.old
  touch /srv/fai_netscript_done
}

fai_setup() {
  # if testing FAI 4.x do not use existing base.tgz
  FAI_VERSION=$(dpkg --list fai-server | awk '/^ii/ {print $3}')
  if dpkg --compare-versions $FAI_VERSION gt 3.5 ; then
    echo "Not installing base.tgz, as version of FAI greater than 3.5."
  else
    # download base.tgz to save time...
    # TODO: support different archs, detect etch/lenny/....
    if wget 10.0.2.2:8000/base.tgz ; then
      [ -d /srv/fai/config/basefiles/ ] || mkdir /srv/fai/config/basefiles/
      mv base.tgz /srv/fai/config/basefiles/FAIBASE.tgz
    fi
  fi

  if ! [ -d /srv/fai/nfsroot/live/filesystem.dir ] ; then
    log "Executing fai-setup"
    if [ -r /srv/fai/config/basefiles/FAIBASE.tgz ] ; then
      fai-setup -v -B /srv/fai/config/basefiles/FAIBASE.tgz | tee /tmp/fai-setup.log
    else
      fai-setup -v | tee /tmp/fai-setup.log
    fi
  fi

  if ! [ -e /srv/tftp/fai/pxelinux.cfg/default ] ; then
    ln -s $(find /srv/tftp/fai/pxelinux.cfg/ -type f -print0 | head -1) /srv/tftp/fai/pxelinux.cfg/default
  fi
}

adjust_services() {
  log "Restarting services"
  # brrrrr, but works...
  /etc/init.d/portmap restart
  /etc/init.d/nfs-common restart
  /etc/init.d/nfs-kernel-server restart || true

  if [ -x /etc/init.d/dnsmasq ] ; then
    /etc/init.d/dnsmasq restart
  fi

  # inetutils-inetd might not be present
  if [ -x /etc/init.d/inetutils-inetd ] ; then
    /etc/init.d/inetutils-inetd stop || true
    rm -f /etc/rc2.d/S20inetutils-inetd
  fi

  /etc/init.d/tftpd-hpa restart

  if [ -x /etc/init.d/dhcp3-server ] ; then
    /etc/init.d/dhcp3-server restart
  else
    /etc/init.d/isc-dhcp-server restart
  fi
}

demohost() {
  log "Executing fai-chboot for $DEMOHOST"
  fai-chboot -IFv "${DEMOHOST}"
}
# }}}

# main execution itself {{{

main() {
  get_fai_config
  software_install
  prechecks
  dhcpd_conf
  tftpd_conf
  network_conf
  hosts_conf
  fai_conf
  disk_setup
  nfs_setup
  fai_setup
  adjust_services
  demohost
}

# if executed via netscript bootoption
# a simple, stupid and not-yet-100% reliable check
if [[ "$SHLVL" == "2" ]] ; then
  main
  rc=$?
fi
# }}}

#) 2>&1 | tee "$myname".errors >&2) 3>&1 | tee "$myname".log
#rc=$(cat "$myname".rc 2>/dev/null)
#rm -f "$myname".rc

echo "status report from $(date)" | telnet 10.0.2.2 8888
echo "rc=$rc" | telnet 10.0.2.2 8888
echo "done" | telnet 10.0.2.2 8888

#exit $rc

## END OF FILE #################################################################