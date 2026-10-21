struct Packet { int size; int flags; };
int packet_send(struct Packet *packet);
int packet_legacy(void);
#define PACKET_LIMIT 64
