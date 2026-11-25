// stb_vorbis with decoders that share the setup of another one: the
// codebooks, floors, residues, mappings and transform tables a Vorbis setup
// header expands to, which every file encoded with the same setup decodes
// with. A shared decoder holds only its state of decoding (the channel
// buffers, the previous window and the floor of each channel, and the
// workspace of a packet), so a voice of a sound costs a few tens of KB and
// opens without parsing the headers again.

#include "stb_vorbis.c"

// Where the audio of a file is, as an open decoder of it found: what a shared
// decoder of that file needs besides the setup.
typedef struct
{
   unsigned int first_audio_page_offset;
   unsigned int total_samples;
   ProbedPage first, last;
} stb_vorbis_place;

// The place of an open decoder, its length measured first.
void stb_vorbis_get_place(stb_vorbis *f, stb_vorbis_place *place)
{
   stb_vorbis_stream_length_in_samples(f);
   place->first_audio_page_offset = f->first_audio_page_offset;
   place->total_samples = f->total_samples;
   place->first = f->p_first;
   place->last = f->p_last;
}

static int shared_floor_values(const stb_vorbis *setup)
{
   int i, values = 0;
   for (i=0; i < setup->floor_count; ++i)
      if (setup->floor_types[i] == 1 && setup->floor_config[i].floor1.values > values)
         values = setup->floor_config[i].floor1.values;
   return values;
}

// The bytes of the alloc buffer a shared decoder of setup takes.
int stb_vorbis_shared_memory_required(const stb_vorbis *setup)
{
   int per_channel = ((4*setup->blocksize_1+7)&~7) + ((2*setup->blocksize_1+7)&~7) + ((2*shared_floor_values(setup)+7)&~7);
   return ((int) sizeof(stb_vorbis)+7&~7) + setup->channels*per_channel + ((int) setup->temp_memory_required+7&~7);
}

// A decoder of the file in data, at its place, with the setup of setup, which
// must have been opened from a file whose identification and setup headers
// are the same bytes. setup is only read: it must outlive the decoder and is
// not decoded with. The decoder is at the start of the file, as one that
// stb_vorbis_open_memory returns, and takes all its memory from alloc.
stb_vorbis *stb_vorbis_open_shared(const stb_vorbis *setup, const unsigned char *data, int len, const stb_vorbis_place *place, const stb_vorbis_alloc *alloc, int *error)
{
   stb_vorbis p, *f;
   int i, values = shared_floor_values(setup);
   p = *setup;
   p.alloc = *alloc;
   p.alloc.alloc_buffer_length_in_bytes &= ~7;
   p.setup_offset = 0;
   p.temp_offset = p.alloc.alloc_buffer_length_in_bytes;
   p.setup_memory_required = 0;
   p.eof = 0;
   p.error = VORBIS__no_error;
   p.vendor = NULL;
   p.comment_list = NULL;
   p.comment_list_length = 0;
   p.stream = p.stream_start = (uint8 *) data;
   p.stream_end = (uint8 *) data + len;
   p.stream_len = len;
   p.first_audio_page_offset = place->first_audio_page_offset;
   p.total_samples = place->total_samples;
   p.p_first = place->first;
   p.p_last = place->last;
   // The state of decoding of setup is of its own file: that of a decoder just opened.
   p.current_loc_valid = FALSE;
   p.last_seg = FALSE;
   p.acc = 0;
   p.valid_bits = 0;
   p.packet_bytes = 0;
   p.bytes_in_seg = 0;
   p.discard_samples_deferred = 0;
   p.samples_output = 0;
   p.channel_buffer_start = p.channel_buffer_end = 0;
   f = vorbis_alloc(&p);
   if (f == NULL || alloc->alloc_buffer_length_in_bytes < stb_vorbis_shared_memory_required(setup)) {
      if (error) *error = VORBIS_outofmem;
      return NULL;
   }
   *f = p;
   for (i=0; i < f->channels; ++i) {
      f->channel_buffers[i] = (float *) setup_malloc(f, sizeof(float) * f->blocksize_1);
      f->previous_window[i] = (float *) setup_malloc(f, sizeof(float) * f->blocksize_1/2);
      f->finalY[i]          = (int16 *) setup_malloc(f, sizeof(int16) * values);
      memset(f->channel_buffers[i], 0, sizeof(float) * f->blocksize_1);
   }
   if (!stb_vorbis_seek_start(f)) {
      if (error) *error = f->error ? f->error : VORBIS_invalid_first_page;
      return NULL;
   }
   if (error) *error = VORBIS__no_error;
   return f;
}
