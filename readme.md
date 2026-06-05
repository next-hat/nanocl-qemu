# nanocl-qemu

Nanocl qemu is a container image thinked to run virtual machine.
The virtual machine will take the ip of the started container has his own ip.
To do so your image must be compatible with `cloud-init`.
Most of cloud image have it baseline.

## Get started

Start to download our image:

```sh
docker pull ghcr.io/next-hat/nanocl-qemu:latest
```

Then choose you'r cloud image.
I'll be using official latest ubuntu lts version:

```sh
wget https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img

wget https://cloud-images.ubuntu.com/minimal/releases/resolute/release/ubuntu-26.04-minimal-cloudimg-amd64.img

```


You can resize it to fit your need:

```
qemu-img resize ubuntu-22.04-minimal-cloudimg-amd64.img 50G
```

Then you can start your container as a virtual machine using:

```sh
docker run -it --rm \
  --cap-add NET_ADMIN \
  -v $(pwd)/ubuntu-22.04-minimal-cloudimg-amd64.img:/img/server.img \
  ghcr.io/next-hat/nanocl-qemu:latest -m 4G -smp 4 -hda /img/server.img
```

Default user and password is set to `cloud:cloud`

You can tweak settings like the default user, the password and add an ssh key with environment variables:

```sh
docker run -it --rm \
  --cap-add NET_ADMIN \
  -e USER="$USER" \
  -e SSH_KEY="$SSH_KEY" \
  -e PASSWORD="$PASSWORD" \
  -v $(pwd)/ubuntu-26.04-minimal-cloudimg-amd64.img:/img/server.img \
  ghcr.io/next-hat/nanocl-qemu:latest -m 4G -smp 4 -hda /img/server.img
```

The container runs headless by default. Use environment variables for the runtime mode instead of special command-line flags.

`GRAPHIC=true` enables a local graphical QEMU window when you pass the host X11 environment into the container.

`GRAPHIC_BACKEND` controls the graphical backend (`auto`, `gtk`, or `sdl`). Default is `auto`.

`WEBSOCKIFY=true` enables a browser-friendly remote display path by starting QEMU with VNC and bridging it through websockify on port `6080`.

`SPICE=true` is kept in the launcher for a later SPICE-capable image, but it is not the recommended path with the current image.

For `GRAPHIC=true`, make sure you are using an image built from the current Dockerfile so the GTK display backend is included.

To open a local GUI from the container, pass the X11 environment and sockets through Docker:

```sh
xhost +local:root

docker run -it --rm \
  --device=/dev/kvm \
  --cap-add NET_ADMIN \
  -e GRAPHIC=true \
  -e DISPLAY="$DISPLAY" \
  -e NO_AT_BRIDGE=1 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$HOME/.Xauthority:/root/.Xauthority:ro" \
  -v $(pwd)/ubuntu-26.04-minimal-cloudimg-amd64.img:/img/server.img \
  ghcr.io/next-hat/nanocl-qemu:latest -accel kvm -m 4G -smp 4 -hda /img/server.img
```

You can still pass raw QEMU arguments after the image name. For example, `-accel kvm`, `-m 4G`, and `-smp 4` are forwarded directly to QEMU.

GUI troubleshooting:

- `Failed to load module "canberra-gtk-module"` and pixbuf warnings are GTK runtime warnings from inside the container and do not always block boot.
- If you see a black graphics area with Ubuntu cloud images, this is expected in many cases: cloud images are usually serial/headless oriented and often do not provide a desktop framebuffer.
- If GTK rendering looks broken on your host, force SDL as a fallback:

```sh
docker run -it --rm \
  --device=/dev/kvm \
  --cap-add NET_ADMIN \
  -e GRAPHIC=true \
  -e GRAPHIC_BACKEND=sdl \
  -e DISPLAY="$DISPLAY" \
  -e NO_AT_BRIDGE=1 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$HOME/.Xauthority:/root/.Xauthority:ro" \
  -v $(pwd)/ubuntu-26.04-minimal-cloudimg-amd64.img:/img/server.img \
  ghcr.io/next-hat/nanocl-qemu:latest -accel kvm -m 4G -smp 4 -hda /img/server.img
```

If you want to enable kvm it's possible too:

```sh
docker run -it --rm \
  --device=/dev/kvm \
  --cap-add NET_ADMIN \
  -e USER="$USER" \
  -e SSH_KEY="$SSH_KEY" \
  -e PASSWORD="$PASSWORD" \
  -v $(pwd)/ubuntu-26.04-minimal-cloudimg-amd64.img:/img/server.img \
  ghcr.io/next-hat/nanocl-qemu:latest -accel kvm -m 4G -smp 4 -hda /img/server.img
```

If you enable `WEBSOCKIFY=true`, publish the websocket port as well:

```sh
docker run -it --rm \
  --cap-add NET_ADMIN \
  -p 6080:6080 \
  -e WEBSOCKIFY=true \
  -e WEBSOCKIFY_PORT=6080 \
  -e VNC_DISPLAY=0 \
  -v $(pwd)/ubuntu-26.04-minimal-cloudimg-amd64.img:/img/server.img \
  ghcr.io/next-hat/nanocl-qemu:latest -m 4G -smp 4 -hda /img/server.img
```

This starts QEMU with an internal VNC server and exposes a websocket bridge on port `6080`.

You still need a web VNC client such as noVNC to connect from the browser. `websockify` is only the websocket proxy; it does not provide the browser UI by itself.
