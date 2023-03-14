# nanocl-qemu

Nanocl qemu is a container image thinked to run virtual machine.
The virtual machine will take the ip of the started container has his own ip.
To do so your image must be compatible with `cloud-init`.
Most of cloud image have it baseline.

## Get started

Start to download our image:

```sh
docker pull nexthat/nanocl-qemu:latest
```

Then choose you'r cloud image.
I'll be using official latest ubuntu lts version:

```sh
wget https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img
```

You can resize it to fit your need:

```
qemu-img resize ubuntu-22.04-minimal-cloudimg-amd64.img 50G
```

Then you can start your container as a virtual machine using:

```sh
docker run -it --rm \
  --device=/dev/net/tun \
  --cap-add NET_ADMIN \
  -v $(pwd)/ubuntu-22.04-minimal-cloudimg-amd64.img:/img/server.img \
  nexthat/nanocl-qemu:latest -m 4G -smp 4 -hda /img/server.img
```

Default user and password is set to `cloud:cloud`

You can tweak some settings like the default user, the password and add ssh_key as follow

```sh
docker run -it --rm \
  --device=/dev/net/tun \
  --cap-add NET_ADMIN \
  -e USER="$USER" \
  -e SSH_KEY="$SSH_KEY" \
  -e PASSWORD="$PASSWORD" \
  -v $(pwd)/ubuntu-22.04-minimal-cloudimg-amd64.img:/img/server.img \
  nexthat/nanocl-qemu:latest -m 4G -smp 4 -hda /img/server.img
```

If you want to enable kvm it's possible too:

```sh
docker run -it --rm \
  --device=/dev/kvm \
  --device=/dev/net/tun \
  --cap-add NET_ADMIN \
  -e USER="$USER" \
  -e SSH_KEY="$SSH_KEY" \
  -e PASSWORD="$PASSWORD" \
  -v $(pwd)/ubuntu-22.04-minimal-cloudimg-amd64.img:/img/server.img \
  nexthat/nanocl-qemu:latest -accel kvm -m 4G -smp 4 -hda /img/server.img
```
