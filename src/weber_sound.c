#include <portaudio.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define TRUE 1
#define FALSE 0

#ifdef MACOS
#define EXPORT __attribute__((visibility("default")))
#define Int16 __int16_t
#endif
#ifdef WINDOWS
#define EXPORT __declspec(dllexport)
#define Int16 int16_t
#endif

#define NO_CHANNELS -2

typedef struct{
  Int16* buffer;
  int len;
}Sound;

typedef struct{
  Int16* buffer;
  PaTime start;
  int offset;
  int len;
}TimedSound;

TimedSound* newTimedSound(TimedSound* sound,Sound* x,PaTime start){
  sound->buffer = x->buffer;
  sound->len = x->len;
  sound->start = start;
  sound->offset = 0;
  return sound;
}

typedef struct{
  TimedSound** data;
  int len;
  int paused;
  int consumer_index;
  int producer_index;
  PaTime done_at;
}Sounds;

Sounds* newSounds(Sounds* sounds,int queue_size){
  sounds->data = (TimedSound**)malloc(sizeof(TimedSound*)*queue_size);
  sounds->len = queue_size;
  sounds->paused = FALSE;
  sounds->consumer_index = 0;
  sounds->producer_index = 0;
  sounds->done_at = 0;
  for(int j=0;j<queue_size;j++) sounds->data[j] = NULL;

  return sounds;
}

void freeSounds(Sounds* sounds){
  while(sounds->data[sounds->consumer_index]){
    free(sounds->data[sounds->consumer_index]);
    sounds->data[sounds->consumer_index] = 0;
    sounds->consumer_index++;
    if(sounds->consumer_index == sounds->len)
      sounds->consumer_index = 0;
  }
  free(sounds->data);
}

typedef struct{
  Sounds* data;
  int len;
  int playback_error;
  unsigned long last_buffer_size;
  PaTime last_latency;

  double samplerate;
  double samplelen; // redundant, but reduces calculations in callback
}Channels;

Channels* newChannels(Channels* channels,int samplerate,int num_channels,int queue_size){
  channels->data = (Sounds*)malloc(sizeof(Sounds)*2*num_channels);
  channels->len = 2*num_channels;

  channels->playback_error = 0;
  channels->last_buffer_size = 0;
  channels->last_latency = 0;
  channels->samplerate = samplerate;
  channels->samplelen = 1.0/samplerate;

  int i;
  for(i=0;i<num_channels;i++)
    newSounds(channels->data + i,queue_size);
  // streaming channels have a small queue
  for(;i<2*num_channels;i++)
    newSounds(channels->data + i,2);

  return channels;
}

void freeChannels(Channels* channels){
  for(int i=0;i<channels->len;i++) freeSounds(channels->data + i);
  free(channels->data);
  free(channels);
}

typedef struct{
  PaError errcode;
  int weber_error;
  Channels* channels;
  PaStream* stream;
}WsState;

int first_loop = TRUE;

static int ws_callback(const void* in,void* out,unsigned long len,
                       const PaStreamCallbackTimeInfo* time_info,
                       PaStreamCallbackFlags status_flags,void* user_data){
  Channels* channels = (Channels*)user_data;
  Int16* output_buffer = (Int16*)out;
  int outi=0;
  int should_start = FALSE;
  int old_index;
  PaTime buffer_start = time_info->outputBufferDacTime;

  for(outi=0;outi<len;outi++){
    output_buffer[(outi<<1)] = 0;
    output_buffer[(outi<<1)+1] = 0;
  }

  channels->last_latency = time_info->outputBufferDacTime - time_info->currentTime;
  channels->last_buffer_size = len;

  for(int c=0;c<channels->len;c++){
    Sounds* sounds = channels->data + c;
    TimedSound* sound;
    if(sounds->paused) continue;

    int zero_padding=0;
    outi=0;
    // if there's nothing to consume on this channel
    // update done_at to indicate when the next time
    // sounds can start playing on this channel
    if(!sounds->data[sounds->consumer_index])
      sounds->done_at = buffer_start + channels->samplelen*len;
    while( (sound = sounds->data[sounds->consumer_index]) && outi < len ){
      if(sound->offset == 0){
        // if the sound should start in this callback...
        if(sound->start > 0){
          // ..find out where it should start.
          if(buffer_start + channels->samplelen * len > sound->start){
            zero_padding = (int)floor((sound->start - buffer_start)*channels->samplerate);
            sounds->done_at = sound->start + sound->len*channels->samplelen;
            should_start = TRUE;

            if(zero_padding < outi){
              channels->playback_error = zero_padding - outi;
              zero_padding = outi;
              sounds->done_at = buffer_start + zero_padding*channels->samplelen +
                sound->len*channels->samplelen;
            }
          }else outi = len;
        }else{
          sounds->done_at = buffer_start + zero_padding*channels->samplelen +
            sound->len*channels->samplelen;
          zero_padding = outi;
          should_start = TRUE;
        }
      }

      // sum samples to output as needed
      int offset = sound->offset;
      if((offset > 0 || should_start) && offset < sound->len){
        for(outi=zero_padding;outi < len && outi-zero_padding < sound->len - offset;outi++){
          output_buffer[(outi<<1)] += sound->buffer[outi-zero_padding+offset];
          output_buffer[(outi<<1)+1] += sound->buffer[outi-zero_padding+sound->len+offset];
        }
        sound->offset = len-zero_padding + offset;
      }

      // if we're done with the sound, remove sound from ring buffer
      if(sound->offset >= sound->len){
        free(sound);

        old_index = sounds->consumer_index++;
        if(sounds->consumer_index == sounds->len) sounds->consumer_index = 0;
        sounds->data[old_index] = NULL;
      }
    }
  }
  return 0;
}

EXPORT
int ws_play(double now,double playat,int channel,Sound* toplay,WsState* state){
  PaTime pa_now = Pa_GetStreamTime(state->stream);
  PaTime time = (pa_now - now) + playat;

  // create the sound
  TimedSound* sound = newTimedSound((TimedSound*)malloc(sizeof(TimedSound)),toplay,time);

  // find the available channel soonest to be done playing a sound
  if(channel < 0){
    PaTime min_done_at = INFINITY;
    for(int i=0;i<state->channels->len / 2;i++){
      Sounds* sounds = state->channels->data + i;
      if(sounds->paused) continue;
      if(sounds->data[sounds->producer_index] != NULL) continue;
      if(min_done_at > state->channels->data[i].done_at){
        channel = i;
        min_done_at = state->channels->data[i].done_at;
      }
    }
    if(channel < 0){
      state->weber_error = NO_CHANNELS;
      return -1;
    }
  }

  // printf("playing on channel: %d\n",channel);

  // add the sound to this channel at the appropriate time
  Sounds* sounds = state->channels->data + channel;
  sounds->data[sounds->producer_index] = sound;

  // printf("channel: %d\n",channel);
  // printf("sounds->consumer_index: %d\n",sounds->consumer_index);
  // printf("sounds->producer_index: %d\n",sounds->producer_index);
  // printf("sounds->data[sounds->producer_index]: %p\n",
  //       (void*)sounds->data[sounds->producer_index]);

  sounds->producer_index++;
  if(sounds->producer_index == sounds->len)
    sounds->producer_index = 0;

  // printf("YO!\n");

  return channel;
}

// TODO: i think what's happening is that the new sound is getting swapped out
// because where quickly overriding the capacity of the queue. THis explains
// why the clicking stops when we stop streaming, and then runs smoothly
// until the end.

EXPORT
double ws_play_next(double now,int channel,Sound* toplay,WsState* state){
  // play_next uses a spearate set of channels
  channel = state->channels->len/2 + channel;

  // create the sound
  PaTime pa_now = Pa_GetStreamTime(state->stream);
  TimedSound* sound = newTimedSound((TimedSound*)malloc(sizeof(TimedSound)),toplay,-1);

  // add the sound to this channel, unpausing if necessary
  Sounds* sounds = state->channels->data + channel;
  if(sounds->paused){
    TimedSound* paused_sound = sounds->data[sounds->consumer_index];
    paused_sound->offset = paused_sound->len;
    sounds->paused = FALSE;
  }

  double done_at = sounds->done_at + toplay->len*state->channels->samplelen;
  if(!sounds->data[sounds->producer_index]){
    sounds->data[sounds->producer_index] = sound;

    sounds->producer_index++;
    if(sounds->producer_index == sounds->len)
      sounds->producer_index = 0;

    return (done_at - pa_now) + now;
  }else{
    return -1.0;
  }
}

EXPORT
const char* ws_warn_str(WsState* state){
 if(state->channels != 0 && state->channels->playback_error < 0){
   double latency = -state->channels->playback_error * state->channels->samplelen;
   state->channels->playback_error = 0;
   static char warn[100];
   snprintf(warn,sizeof(warn),"A previously played sound occured %3.2fms"
            " after it should have.",latency*1000);
   return warn;
 }
 return "";
}

EXPORT
const char* ws_error_str(WsState* state){
  if(state->errcode != paNoError)
    return Pa_GetErrorText(state->errcode);
  else if(state->weber_error != 0){
    if(state->weber_error == NO_CHANNELS)
      return "All unpaused channels have full buffers.";
    else{
      static char err[25];
      sprintf(err,"Unknown Error Code: %03d",state->weber_error);
      return err;
    }
  }
  return "";
}

EXPORT
WsState* ws_setup(int samplerate,int num_channels,int queue_size){
  WsState* state = (WsState*) malloc(sizeof(WsState));
  state->weber_error = 0;
  state->errcode = Pa_Initialize();
  if(state->errcode != paNoError){
    state->stream = 0;
    state->channels = 0;
    state->weber_error = 0;
    return state;
  }
  state->channels = newChannels((Channels*)malloc(sizeof(Channels)),samplerate,
                                   num_channels,queue_size);

  state->errcode = Pa_OpenDefaultStream(&state->stream,0,2,paInt16,samplerate,
                                        paFramesPerBufferUnspecified,ws_callback,
                                        state->channels);

  if(state->errcode != paNoError){
    for(int i=0;i<2*num_channels;i++) free(state->channels->data);
    free(state->channels);
    state->channels = 0;
    state->stream = 0;
    state->weber_error = 0;
    return state;
  }

  if(paNoError != (state->errcode = Pa_StartStream(state->stream))){
    for(int i=0;i<2*num_channels;i++) free(state->channels->data);
    free(state->channels);
    state->channels = 0;
    state->stream = 0;
    state->weber_error = 0;
    return state;
  }

  return state;
}

EXPORT
void ws_close(WsState* state){
  if(paNoError != (state->errcode = Pa_StopStream(state->stream))) return;
  if(paNoError != (state->errcode = Pa_CloseStream(state->stream))) return;
  if(state->channels != 0){
    freeChannels(state->channels);
    state->channels = 0;
  }
  state->errcode = Pa_Terminate();
}

EXPORT
void ws_free(WsState* state){
  free(state);
}

EXPORT
void ws_pause(WsState* state,int channel,int isstream,int pause){
  if(channel < 0){
    for(int i=0;i<state->channels->len;i++){
      state->channels->data[i].paused = pause;
    }
  }
  if(isstream)
    state->channels->data[state->channels->len/2 + channel].paused = pause;
  else
    state->channels->data[channel].paused = pause;
}

EXPORT
double ws_cur_latency(WsState* state){
  return state->channels->last_buffer_size / state->channels->samplerate +
    state->channels->last_latency;
}