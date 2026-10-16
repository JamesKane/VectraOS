# D62. GPU hardware floor and driver order (2026-10-16, proposed)

todhchai states Loinnir's floor as "descriptor heaps and buffer device
address: RDNA2, Xe, Turing or newer", and orders native drivers AMD,
Intel, NVIDIA, then arm64 GPUs.
- **The floor is stated as capabilities** (buffer device address,
  bindless descriptors in GPU memory, timeline semaphores, dynamic
  rendering), checked for each GPU we name, since we write the drivers and
  what matters is the hardware, not today's driver releases.
- **Two device lists:** the boards' (Adreno 690, Mali-G720, the Ky X1's
  GPU) and the desktop's (AMD, Intel, NVIDIA). The 2013 Mac Pro's
  FirePro (GCN 1.0) is the oldest on either; whether it meets the floor
  decides whether descriptor heaps are required or preferred. The Ky X1's
  GPU is to be verified.
- **Two driver tracks:** the boards' (Adreno first, for V6's display and
  V8's compute) and the desktop's (AMD, Intel, NVIDIA, as todhchai has
  them). Until a desktop driver exists, desktops run Loinnir through
  Venus in a VM. When the desktop track starts is open.
