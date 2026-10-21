struct Packet { long size; int flags; int priority; };
int packet_send(struct Packet *packet);
void packet_reset(struct Packet *packet);
#define PACKET_LIMIT 128
