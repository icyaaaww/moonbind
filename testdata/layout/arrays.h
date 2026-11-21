// struct ArrayBoundary
struct ArrayBoundary {
  unsigned char prefix;
  unsigned short samples[3];
  unsigned int code;
};

// union ArrayOverlay
union ArrayOverlay {
  unsigned char bytes[7];
  unsigned int words[2];
};

// struct TailPadding
struct TailPadding {
  double value;
  unsigned char flags[3];
};
