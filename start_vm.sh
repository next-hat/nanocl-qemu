# -e NO_AT_BRIDGE=1 \
# -e DISPLAY=$DISPLAY \
# -v $(pwd)/seed.img:/img/seed.img \
# -v /tmp/.X11-unix:/tmp/.X11-unix \
# -v $HOME/.Xauthority:/root/.Xauthority \
docker run -it --rm \
  --device=/dev/kvm \
  --cap-add NET_ADMIN \
  -e SSH_KEY="$SSH_KEY" \
  -e USER="$USER" \
  -e PASSWORD="$PASSWORD" \
  -v $(pwd)/server.img:/img/server.img \
  nanocl-qemu:latest -accel kvm -m 4G -smp 4 -hda /img/server.img
