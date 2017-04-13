using DSP
using FixedPointNumbers
using FileIO
using LRUCache
using Lazy
using Unitful
import Unitful: ms, s, kHz, Hz

import FileIO: load, save
import DSP: resample
import LibSndFile
import SampledSignals: samplerate
import SampledSignals
import Distributions: nsamples
import Base: show, length, start, done, next, linearindexing, size, getindex,
  setindex!, vcat, similar, convert, .*, .+

# TODO: separate out sound object, from sound creation
# from streaming from audio playback into separate files

# TODO: define streaming and sounds with same code that
# makes call to general function which takes a standard interface
# for defining elements of the sound

export mix, mult, silence, envelope, noise, highpass, lowpass, bandpass,
  bandstop, tone, ramp, harmonic_complex, attenuate, sound, asstream, play,
  stream, stop, duration, nchannels, nsamples, setup_sound,
  current_sound_latency, buffer, resume_sounds, pause_sounds, loadsound,
  save, samplerate, length, channel, rampon, rampoff, stream_unit, fadeto,
  ms, s, kHz, Hz, vcat, leftright, similar, .., between, left, right

# TODO: I will probably reimplement streams using a different
# interface, to allow said interface to request how much
# of the stream to present, rather than fixing that value,
# this means I probably shouldn't bother troubleshooting
# the streaming functions, since they'll change quickly anyways
# (might be worth commenting them out....)

const weber_sound_version = 2

let
  version_in_file =
    match(r"libweber-sound\.([0-9]+)\.(dylib|dll)",weber_sound).captures[1]
  if parse(Int,version_in_file) != weber_sound_version
    error("Versions for weber sound driver do not match. Please run ",
          "Pkg.build(\"Weber\").")
  end
end

immutable Sound{R,T,N} <: AbstractArray{T,N}
  data::Array{T,N}
  function Sound(a::Array{T,N})
    if T <: Integer
      error("Cannot use integer arrays for a sound. ",
            "Use FixedPointNumbers instead.")
    end

    if N == 1
      new(a)
    elseif N == 2
      new(a)
    else
      error("Unexpected dimension count $N for sound array, should be 1",
            " (for mono) or 2 (for mono or stereo).")
    end
  end
end
convert{R,T,N}(::Type{Sound{R,T,N}},x) = Sound{R,T,N}(convert(Array{T,N},x))
function convert{R,T,S,N}(::Type{Sound{R,T,N}},x::Sound{R,S,N})
  Sound{R,T,N}(convert(Array{T,N},x.data))
end
function convert{R,Q,T,S}(::Type{Sound{R,T}},x::Sound{Q,S})
  error("Cannot convert a sound with sampling rate $(Q*Hz) to a sound with ",
        "sampling rate $(R*Hz). Use `resample` to change the sampling rate.")
end
typealias TimeDim Unitful.Dimensions{(Unitful.Dimension{:Time}(1//1),)}
typealias FreqDim Unitful.Dimensions{(Unitful.Dimension{:Time}(-1//1),)}
typealias Time{N} Quantity{N,TimeDim}
typealias Freq{N} Quantity{N,FreqDim}

samplerate{R}(x::Sound{R}) = R*Hz
length(x::Sound) = length(x.data)

"""
    duration(x)

Get the duration of the given sound in seconds.
"""
duration{R}(x::Sound{R}) = uconvert(s,nsamples(x) / (R*Hz))
nchannels(x::Sound) = size(x.data,2)

"""
    nsamples(x::Sound)

Returns the number of samples in the sound.
"""
nsamples(x::Sound) = size(x.data,1)
size(x::Sound) = size(x.data)
linearindexing(t::Type{Sound}) = Base.LinearSlow()

# adapted from:
# https://github.com/JuliaAudio/SampledSignals.jl/blob/0a31806c3f7d382c9aa6db901a83e1edbfac62df/src/SampleBuf.jl#L109-L139
function show{R}(io::IO, x::Sound{R})
  seconds = round(ustrip(duration(x)),ceil(Int,log(10,R)))
  typ = if eltype(x) == Q0f15
    "16 bit PCM"
  elseif eltype(x) <: AbstractFloat
    "$(sizeof(eltype(x))*8) bit floating-point"
  else
    eltype(x)
  end

  channel = size(x.data,2) == 1 ? "mono" : "stereo"

  println(io, "$seconds s $typ $channel sound")
  print(io, "Sampled at $(R*Hz)")
  nsamples(x) > 0 && showchannels(io, x)
end
show(io::IO, ::MIME"text/plain", x::Sound) = show(io,x)

const ticks = ['_','▁','▂','▃','▄','▅','▆','▇']
function showchannels(io::IO, x::Sound, widthchars=80)
  # number of samples per block
  blockwidth = round(Int, nsamples(x)/widthchars, RoundUp)
  nblocks = round(Int, nsamples(x)/blockwidth, RoundUp)
  blocks = Array(Char, nblocks, nchannels(x))
  for blk in 1:nblocks
    i = (blk-1)*blockwidth + 1
    n = min(blockwidth, nsamples(x)-i+1)
    peaks = sqrt.(mean(float(x[(1:n)+i-1,:]).^2,1))
    # clamp to -60dB, 0dB
    peaks = clamp(20log10(peaks), -60.0, 0.0)
    idxs = trunc(Int, (peaks+60)/60 * (length(ticks)-1)) + 1
    blocks[blk, :] = ticks[idxs]
  end
  for ch in 1:nchannels(x)
    println(io)
    print(io, convert(String, blocks[:, ch]))
  end
end


@inline function getindex(x::Sound,i::Int)
  @boundscheck checkbounds(x.data,i)
  @inbounds return x.data[i]
end

@inline function setindex!{R,T,S}(x::Sound{R,T},v::S,i::Int)
  @boundscheck checkbounds(x.data,i)
  @inbounds return x.data[i] = convert(T,v)
end


@inline function getindex(x::Sound,i::Int,j::Int)
  @boundscheck checkbounds(x.data,i,j)
  @inbounds return x.data[i,j]
end

@inline function setindex!{R,T,S}(x::Sound{R,T},v::S,i::Int,j::Int)
  @boundscheck checkbounds(x.data,i,j)
  @inbounds return x.data[i,j] = convert(T,v)
end

"""
    left(sound::Sound)

Extract the left channel a sound.

For a single channel (mono) sound, this transforms the sound into a stereo sound
with the given samples as the left channel, and a silent right channel. For a
double channel (stereo) sound, this transforms the sound into a stereo
sound with a silenced right channel.
"""
function left{R,T,N}(sound::Sound{R,T,N})
  channel = if size(sound.data,2) == 1
    sound.data
  else
    sound.data[:,1]
  end
  Sound{R,T,N}(hcat(channel,(zereos(T,size(sound,1)))))
end

"""
    right(sound::Sound)

Extract the right channel of a sound.

For a single channel (mono) sound, this transforms the sound into a stereo sound
with the given samples as the right channel, and a silent left channel. For a
double channel (stereo) sound, this transforms the sound into a stereo
sound with a silenced left channel.
"""
function right{R,T,N}(sound::Sound{R,T,N})
  channel = if size(sound.data,2) == 1
    sound.data
  else
    sound.data[:,2]
  end
  Sound{R,T,N}(hcat((zereos(T,size(sound,1))),channel))
end

immutable SampleRange{N,M}
  from::Time{N}
  to::Time{M}
end

immutable SampleEndRange{N}
  from::Time{N}
  possible_end::Int
end

"""
   between(a::Quantity,b::Quantity)
   a .. b

Specifies the range of sound samples in the range [a,b): inclusive of the sound
sample preciesly at time a, all samples between a and b, but excusive of the
sample at time b.

While a and b must normally both be specified as time quantities, a special
exception is made for the use of end, e.g. sound[2s .. end], can be used to
specify all samples occuring from 2 seconds or later.
"""
between{N,M}(from::Time{N},to::Time{M}) = SampleRange(from,to)
between{N}(from::Time{N},to::Int) = SampleEndRange(from,to)
const .. = between

insamples(time,rate) = floor(Int,ustrip(inseconds(time)*inHz(rate)))
function insamples{N,M}(time::Time{N},rate::Freq{M})
  floor(Int,ustrip(uconvert(s,time)*uconvert(Hz,rate)))
end

function checktime(time)
  if time < 0s
    throw(BoundsError("Unexpected negative time."))
  end
end

const Left = typeof(left)
const Right = typeof(right)
@inline @Base.propagate_inbounds function getindex(x::Sound,ixs,js::Left)
  getindex(x,ixs,1)
end
@inline @Base.propagate_inbounds function setindex!(x::Sound,vals,ixs,js::Left)
  setindex!(x,vals,ixs,1)
end
@inline @Base.propagate_inbounds function getindex(x::Sound,ixs,js::Right)
  getindex(x,ixs,2)
end
@inline @Base.propagate_inbounds function setindex!(x::Sound,vals,ixs,js::Right)
  setindex!(x,vals,ixs,2)
end

@inline function getindex{R,T,I,N}(x::Sound{R,T,N},ixs::SampleEndRange,js::I)
  if nsamples(x) == ixs.possible_end
    @boundscheck checktime(ixs.from)
    from = max(1,insamples(ixs.from,R*Hz))
    @boundscheck checkbounds(x.data,from,js)
    @inbounds return Sound{R,T,N}(x.data[from:end,js])
  else
    error("Cannot specify range of samples using a mixture of times and ",
          "integers. Use only integers or only times (but `end` works in ",
          "either context).")
  end
end

@inline function getindex{R,T,I,N}(x::Sound{R,T,N},ixs::SampleRange,js::I)
  @boundscheck checktime(ixs.from)
  from = max(1,insamples(ixs.from,R*Hz))
  to = insamples(ixs.to,R*Hz)-1
  @boundscheck checkbounds(x.data,from,js)
  @boundscheck checkbounds(x.data,to,js)
  @inbounds return Sound{R,T,N}(x.data[from:to,js])
end

@inline function setindex!{R,T,I}(x::Sound{R,T},vals::AbstractVector,
                                  ixs::SampleEndRange,js::I)
  if nsamples(x) == ixs.possible_end
    @boundscheck checktime(ixs.from)
    from = max(1,insamples(ixs.from,R*Hz))
    @boundscheck checkbounds(x.data,from,js)
    @inbounds x.data[from:end,js] = vals
    vals
  else
    error("Cannot specify range of samples using a mixture of times and ",
          "integers. Use only integers or only times (but `end` works in ",
          "either context).")
  end
end

@inline function setindex!{R,T,I}(x::Sound{R,T},vals::AbstractVector,
                                  ixs::SampleRange,js::I)
  @boundscheck checktime(ixs.from)
  from = max(1,insamples(ixs.from,R*Hz))
  to = insamples(ixs.to,R*Hz)-1
  @boundscheck checkbounds(x.data,from,js)
  @boundscheck checkbounds(x.data,to,js)
  @inbounds x.data[from:to,js] = vals
  vals
end

function similar{R,T,S,N,M}(x::Sound{R,T,N},::Type{S},dims::NTuple{M,Int})
  if M ∉ [1,2] || (M == 2 && dims[2] ∉ [1,2])
    similar(x.data,S,dims)
  else
    Sound{R,S,M}(similar(x.data,S,dims))
  end
end

save(file::Union{AbstractString,IO},sound::Sound) = save(file,assampled(sound))
assampled{R}(x::Sound{R}) = SampledSignals.SampleBuf(x.data,float(R))

"""
    resample(x::Sound,samplerate)

Returns a new sound representing the sound `x` at the given sampling rate.

You will loose all frequencies in the sound above samplerate/2. Resampling
occurs automatically when you call [`sound`](@ref)---which is called inside
[`play`](@ref))---anytime the sampling rate of the sound and the current audio
playback settings (determined by [`setup_sound`](@ref)) are not the same.

To avoid automatic resampling you can either create sounds at the appropriate
sampling rate, as determined by [`samplerate`](@ref) (recommended), or change
the sampling rate initialized during [`setup_sound`](@ref) (not recommended).
"""
function resample{R,T,N}(x::Sound{R,T,N},new_sample_rate)
  new_rate = floor(Int,ustrip(inHz(new_sample_rate)))
  if new_rate < R
    warn("The function `resample` reduced the sample rate, high freqeuncy",
         " information above $(new_rate/2) Hz will be lost ",
         reduce(*,"",map(x -> string(x)*"\n",stacktrace())))
  end
  Sound{new_rate,T,N}(resample(x.data,new_rate // R))
end

function duration(x::Array{Float64};sample_rate_Hz=samplerate())
  uconvert(s,nsamples(x) / inHz(sample_rate_Hz))
end

inHz(x::Quantity) = uconvert(Hz,x)
function inHz(x::Number)
  warn("Unitless value, assuming Hz. Append Hz or kHz to avoid this warning",
       " (e.g. tone(1kHz))",
       reduce(*,"",map(x -> string(x)*"\n",stacktrace())))
  x*Hz
end
inHz{N <: Number,T}(typ::Type{N},x::T) = floor(N,ustrip(inHz(x)))*Hz
inHz{N <: Number}(typ::Type{N},x::N) = inHz(x)
inHz{N <: Number}(typ::Type{N},x::Freq{N}) = inHz(x)

inseconds(x::Quantity) = uconvert(s,x)
function inseconds(x::Number)
  warn("Unitless value, assuming seconds. Append s or ms to avoid this warning",
       " (e.g. silence(500ms))",
       stacktrace())
  x*s
end

const sound_cache = LRU{Any,Sound}(256)
function with_cache(fn,usecache,x)
  if usecache
    get!(fn,sound_cache,object_id(x))
  else
    fn()
  end
end

"""
    sound(x::Array,[cache=true];[sample_rate=samplerate()])

Creates a sound object from an arbitrary array.

Assumes 1 is the loudest and -1 the softest. The array should be 1d for mono
signals, or an array of size (N,2) for stereo sounds.

When cache is set to true, sound will cache its results thus avoiding repeatedly
creating a new sound for the same object.

!!! note "Called Implicitly"

    This function is normally called implicitly in a call to
    `play(x)`, where x is an arbitrary array, so it need not normally
    be called directly.
"""
function sound{T <: Number,N}(x::Array{T,N},cache=true;
                              sample_rate=samplerate())
  if N ∉ [1,2]
    error("Array must have 1 or 2 dimensinos to be converted to a sound.")
  end

  with_cache(cache,x) do
    bounded = max(min(x,typemax(Q0f15)),typemin(Q0f15))
    if size(x,2) == 1
      bounded = hcat(bounded,bounded)
    end
    R = ustrip(inHz(sample_rate))
    Sound{R,Q0f15,N}(Q0f15.(bounded))
  end
end

function sound(x::SampledSignals.SampleBuf,cache=true)
  with_cache(cache,x) do
    R,T = ustrip(inHz(Int,samplerate(x)*Hz)),eltype(x.data)
    sound(Sound{R,T,ndims(x)}(x.data),false)
  end
end

"""
    sound(x::Sound,[cache=true],sample_rate=samplerate())

Regularize the format of a sound.

This will ensure the sound is represented at a given sample rate.
"""

function sound{R,T,N}(x::Sound{R,T,N},cache=true)
  sample_rate=samplerate()
  with_cache(cache,x) do
    bounded = max(min(x.data,typemax(Q0f15)),typemin(Q0f15))
    T2 = Q0f15
    sound(Sound{R,T2,N}(Q0f15.(bounded)),false,sample_rate)
  end
end

function sound{R,N}(x::Sound{R,Q0f15,N},cache=true,sample_rate=samplerate())
  if size(x.data,2) == 2
    if R == ustrip(sample_rate)
      x
    else
      resample(Sound{R,Q0f15,N}(x.data),sample_rate)
    end
  else
    data = hcat(x.data,x.data)
    if R == ustrip(sample_rate)
      Sound{R,Q0f15,N}(data)
    else
      resample(Sound{R,Q0f15,N}(data),sample_rate)
    end
  end
end

"""
    sound(file,[cahce=true])

Load a specified file (e.g. by filename or stream) as a sound.
"""
sound(file::File,cache=true) = sound(load(file),cache)
sound(file::String,cache=true) = sound(load(file),cache)
sound(stream::IOStream) = sound(load(stream),false)

function soundop{R}(op,xs::Union{Sound{R},Array}...)
  len = maximum(map(x -> size(x,1),xs))
  channels = maximum(map(x -> size(x,2),xs))
  y = similar(xs[1],(len,channels))

  for i in 1:size(y,1)
    used = false
    for j in 1:length(xs)
      if i <= size(xs[j],1)
        if !used
          used = true
          @inbounds y[i,:] = xs[j][i,:]
        else
          @inbounds y[i,:] = op(y[i,:],xs[j][i,:])
        end
      end
    end
  end

  y
end

# immutable OpStream
#   streams::Tuple
#   op::Function
# end
# immutable OpState
#   streams::Tuple
#   states::Tuple
# end
# immutable OpPassState
#   stream
#   state
# end

# start(ms::OpStream) = OpState(ms.streams,map(start,ms.streams))
# done(ms::OpStream,state::OpState) = all(map(done,state.streams,state.states))
# done(ms::OpStream,state::OpPassState) = done(state.stream,state.state)
# @inline
# function next(ms::OpStream,state::OpPassState)
#   obj, pass_state = next(state.stream,state.state)
#   obj, OpPassState(state.stream,pass_state)
# end
# function next(ms::OpStream,state::OpState)
#   undone = find(map((stream,state) -> !done(stream,state),state.streams,state.states))
#   streams = state.streams[undone]
#   states = state.states[undone]

#   nexts = map(next,streams,states)
#   sounds = map(x -> x[1],nexts)
#   states = map(x -> x[2],nexts)

#   if length(undone) > 1
#     reduce(ms.op,sounds), OpState(streams,states)
#   else
#     sounds[1], OpPassState(streams[1],states[1])
#   end
# end

"""
    mix(x,y,...)

Mix several sounds (or streams) together so that they play at the same time.

Unlike normal addition, this acts as if each sound is padded with
zeros at the end so that the lengths of all sounds match.
"""
mix{R}(xs::Union{Sound{R},Array}...) = soundop(.+,xs...)
# mix(itrs...) = OpStream(itrs,+)

"""
    mult(x,y,...)

Mutliply several sounds (or streams) together. Typically used to apply an
amplitude envelope.

Unlike normal multiplication, this acts as if each sound is padded with
ones at the end so that the lengths of all sounds match.
"""
mult{R}(xs::Union{Sound{R},Array}...) = soundop(.*,xs...)
# mult(itrs...) = OpStream(itrs,.*)

"""
    silence(length,stereo=true;[sample_rate=samplerate()])

Creates period of silence of the given length (in seconds).
"""
function silence(length,stereo=true;sample_rate=samplerate())
  len = insamples(length,sample_rate)
  N = stereo? 2 : 1
  Sound{ustrip(inHz(Int,sample_rate)),Float64,N}(zeros(len,N))
end

"""
    envelope(mult,length,stereo=true;[sample_rate_Hz=44100])

Creates an evelope of a given multiplier and length (in seconds).

If mult = 0 this is the same as calling silence. This function
is useful in conjunction with [`fadeto`](@ref) and [`mult`](@ref)
when defining an envelope that changes in level. For example,
the following will play a 1kHz tone for 1 second, which changes
in volume halfway through to a softer level.

    mult(tone(1000,1),fadeto(envelope(1,0.5),envelope(0.1,0.5)))

"""
function envelope(mult,length,stereo=true;sample_rate=samplerate())
  N = stereo? 2 : 1
  vals = ones(insample(length,sample_rate),N)
  Sound{ustrip(inHz(Int,sample_rate))}(vals,N)
end


# TODO: implement these functions for streams

"""
    leftright(left,right;[sample_rate=samplerate()])

Create a stereo sound from two vectors or two monaural sounds.

For vectors, one can specify a sample_rate other than the default,
if desired.
"""
function leftright{R,T,N}(x::Sound{R,T,N},y::Sound{R,T,N})
  if size(x.data,2) == size(y.data,2) == 1
    Sound{R,T,2}(hcat(x.data,y.data))
  else
    error("Expected two monaural sounds.")
  end
end

function leftright{T}(x::Vector{T},y::Vector{T};sample_rate=samplerate())
  Sound{ustrip(sample_rate),T,2}(hcat(x,y))
end

# immutable NoiseStream{R,N}
#   rng::RandomDevice
#   length::Int
# end
# show(io::IO,as::NoiseStream) = write(io,"NoiseStream()")
# start(ns::NoiseStream) = nothing
# done(ns::NoiseStream,::Void) = false

"""
    noise(length=Inf,stereo=true;[sample_rate_Hz=44100],[rng=global RNG])

Creates a period of white noise of the given length (in seconds).

You can create an infinite stream of noise (playable with [`stream`](@ref)) by
passing a length of Inf, or leaving out the length entirely.
"""
function noise(length=Inf,stereo=true;
               sample_rate=samplerate(),rng=Base.GLOBAL_RNG)
  R = ustrip(inHz(Int,sample_rate))
  N = stereo? 2 : 1
  if ustrip(length) < Inf
    len = insamples(length,sample_rate)
    if stereo
	    Sound{R,Float64,N}(hcat(1-2rand(rng,len),1-2rand(rng,len)))
    else
      Sound{R,Float64,N}(hcat(1-2rand(rng,len)))
    end
  else
    nothing # NoiseStream{R,stereo? 2 : 1}(RandomDevice(),stream_unit())
  end
end

# function next{R}(ns::NoiseStream{R,1},::Void)
#   Sound{R}(1-2rand(ns.rng,ns.length)), nothing
# end

# function next{R}(ns::NoiseStream{R,2},::Void)
#   Sound{R}(hcat(1-2rand(ns.rng,ns.length),1-2rand(ns.rng,ns.length))), nothing
# end

function tone_helper(t,freq,phase,stereo)
  x = sin(2π*t * freq + phase)
  if stereo
    hcat(x,x)
  else
    x
  end
end

# immutable ToneStream{R,N}
#   freq::Freq{Float64}
#   phase::Float64
#   length::Int
# end
# show(io::IO,as::ToneStream) = write(io,"ToneStream($freq)")
# start(ts::ToneStream) = 1
# done(ts::ToneStream,i::Int) = false

"""
    tone(freq,length;[sample_rate=samplerate()],[phase=0])

Creates a pure tone of the given frequency and length (in seconds).

You can create an infinitely long tone (playable with [`stream`](@ref)) by
passing a length of Inf, or leaving out the length entirely.
"""
function tone(freq,len=Inf,stereo=true;sample_rate=samplerate(),phase=0)
  sample_rate_Hz = inHz(Int,sample_rate)
  R = ustrip(sample_rate_Hz)
  N = stereo? 2 : 1
  if ustrip(len) < Inf
    length_s = inseconds(len)
	  t = linspace(0,ustrip(length_s),ustrip(insamples(length_s,sample_rate_Hz)))
    x = tone_helper(t,ustrip(inHz(freq)),phase,stereo)
    T = eltype(x)
	  Sound{R,T,N}(x)
  else
    nothing # ToneStream{R,N}(inHz(freq_Hz),phase,stream_unit())
  end
end

# function next{R,N}(ts::ToneStream{R,N},i::Int)
#   t = (ts.length*(i-1):ts.length*i-1) ./ R
#   Sound{R}(tone_helper(t,ustrip(ts.freq),ts.phase,N == 2)), i+1
# end

function complex_cycle(f0,harmonics,stereo,amps,sample_rate_Hz,phases)
  @assert all(0 .<= phases) && all(phases .< 2π)
	n = maximum(harmonics)+1

  # generate single cycle of complex
  cycle_length_s = 1/f0
  cycle = zeros(insamples(cycle_length_s,sample_rate_Hz))

	highest_freq = tone(f0,2n*cycle_length_s;sample_rate=sample_rate_Hz)

	for (amp,harm,phase) in zip(amps,harmonics,phases)
		phase_offset = round(Int,n*phase/2π*sample_rate_Hz/f0)
    wave = highest_freq[(1:length(cycle)) * (n-harm) + phase_offset]
		cycle += amp*wave[1:length(cycle)]
	end

  if stereo
    hcat(cycle,cycle)
  else
    cycle
  end
end

# immutable ComplexStream{R,N}
#   cycle::Sound
#   length::Int
#   stereo::Bool
# end
# show(io::IO,as::ComplexStream) = write(io,"ComplexStream(...)")
# start(cs::ComplexStream) = 0
# done(cs::ComplexStream,i::Int) = false

"""
    harmonic_complex(f0,harmonics,amps,length,stereo=false,
                     [sample_rate=samplerate()],[phases=zeros(length(harmonics))])

Creates a harmonic complex of the given length, with the specified harmonics
at the given amplitudes. This implementation is somewhat superior
to simply summing a number of pure tones generated using `tone`, because
it avoids beating in the sound that may occur due floating point errors.

You can create an infinitely long complex (playable with [`stream`](@ref)) by
passing a length of Inf, or leaving out the length entirely.
"""
function harmonic_complex(f0,harmonics,amps,len=Inf,stereo=true;
						              sample_rate=samplerate(),
                          phases=zeros(length(harmonics)))
  sample_rate_Hz = inHz(Int,sample_rate)
  cycle = complex_cycle(inHz(f0),harmonics,stereo,amps,sample_rate_Hz,phases)
  R = ustrip(sample_rate_Hz)
  N = stereo? 2 : 1
  if ustrip(len) < Inf
    n = insamples(len,sample_rate)
    if stereo
      Sound{R,Float64,N}(cycle[(0:n-1) .% size(cycle,1) + 1,:])
    else
      Sound{R,Float64,N}(cycle[(0:n-1) .% size(cycle,1) + 1])
    end
  else
    nothing # ComplexStream{R}(cycle,stream_unit(),stereo)
  end
end

# function next{R}(cs::ComplexStream{R,1},i::Int)
#   Sound{R}(cs.cycle[(i:i+cs.length-1) .% length(cs.cycle) + 1]), i+cs.length
# end

# function next{R}(cs::ComplexStream{R,2},i::Int)
#   Sound{R}(cs.cycle[(i:i+cs.length-1) .% length(cs.cycle) + 1,:]), i+cs.length
# end

# immutable FilterStream{R,T,N,I}
#   filt
#   stream::I
# end
# show(io::IO,filt::FilterStream) = write(io,"FilterStream($filt,$stream)")
# start(fs::FilterStream) = DF2TFilter(fs.filt), start(fs.stream)
# done{T,S}(fs::FilterStream{T},x::Tuple{DF2TFilter,S}) = done(fs.stream,x[2])
# function next{R,T,N,I,J}(fs::FilterStream{R,T,N,I},x::Tuple{DF2TFilter,J})
#   filt_state, state = x
#   new_filt_state = deepcopy(filt_state)
#   sound, state = next(fs.stream,state)

#   Sound{R,T,N}(filt(new_filt_state,sound.data)), (new_filt_state, state)
# end

"""
    bandpass(x,low,high;[order=5])

Band-pass filter the sound (or stream) at the specified frequencies.

Filtering uses a butterworth filter of the given order.
"""
bandpass(x,low,high;order=5) = filter_helper(x,low,high,Bandpass,order)

"""
    bandstop(x,low,high,[order=5],[sample_rate_Hz=samplerate(x)])

Band-stop filter of the sound (or stream) at the specified frequencies.

Filtering uses a butterworth filter of the given order.
"""
bandstop(x,low,high;order=5) = filter_helper(x,low,high,Bandstop,order)

"""
    lowpass(x,low,[order=5],[sample_rate_Hz=samplerate(x)])

Low-pass filter the sound (or stream) at the specified frequency.

Filtering uses a butterworth filter of the given order.
"""
lowpass(x,low;order=5) = filter_helper(x,low,0,Lowpass,order)

"""
    highpass(x,high,[order=5],[sample_rate_Hz=samplerate(x)])

High-pass filter the sound (or stream) at the specified frequency.

Filtering uses a butterworth filter of the given order.
"""
highpass(x,high;order=5) = filter_helper(x,0,high,Highpass,order)

function buildfilt(samplerate,low,high,kind)
  if kind == Bandpass
	  Bandpass(float(ustrip(inHz(low))),float(ustrip(inHz(high))),fs=samplerate)
  elseif kind == Lowpass
    Lowpass(float(ustrip(inHz(low))),fs=samplerate)
  elseif kind == Highpass
    Highpass(float(ustrip(inHz(high))),fs=samplerate)
  elseif kind == Bandstop
    Bandstop(float(ustrip(inHz(low))),float(ustrip(inHz(high))),fs=samplerate)
  end
end

function filter_helper{R,T,N}(x::Sound{R,T,N},low,high,kind,order)
  ftype = buildfilt(R,low,high,kind)
	f = digitalfilter(ftype,Butterworth(order))
  Sound{R,T,N}(mapslices(slice -> filt(f,slice),x.data,1))
end

# function filter_helper(itr,low,hihg,kind;order=5)
#   first_x = first(itr)
#   R = ustrip(samplerate(first_x))
#   T = eltype(first_x)
#   N = ndims(first_x)

#   ftype = buildfilt{R}(low,high,kind)
# 	f = digitalfilter(ftype,Butterworth(order))
#   FilterStream{R,T,N}(f,itr)
# end

"""
    ramp(x,[length=5ms])

Applies a half cosine ramp to start and end of the sound.

Ramps prevent clicks at the start and end of sounds.
"""
function ramp{R}(x::Sound{R},len=5ms)
	ramp_len = insamples(len,R*Hz)
	@assert nsamples(x) > 2ramp_len

	ramp_t = (1.0:ramp_len) / ramp_len
	up = -0.5cos(π*ramp_t)+0.5
	down = -0.5cos(π*ramp_t+π)+0.5
	envelope = [up; ones(size(x,1) - 2*ramp_len); down]
	mult(x,envelope)
end

# immutable FnStream{R}
#   fn::Function
#   length::Int
# end
# start(fs::FnStream) = 1
# done(fs::FnStream,i::Int) = false
# function next{R}(fs::FnStream{R,1},i::Int)
#   t = (fs.length*(i-1):fs.length*i-1) ./ fs.samplerate
#   MonoSound{R}(fs.fn.(t)), i+1
# end

# """
#     asstream(fn;[sample_rate_Hz=44100])

# Converts the function `fn` into a sound stream.

# The function `fn` should take a single argument--the time in seconds from the
# start of the stream--and should return a number between -1 and 1.
# """
# function asstream(fn;sample_rate=samplerate())
#   R = ustrip(inHz(Int,sample_rate))
#   FnStream{R}(fn,stream_unit())
# end

# """
#     rampon(stream,[len=5ms])

# Applies a half consine ramp to start of the sound or stream.
# """
# function rampon(stream,len=5ms)
#   sample_rate = samplerate(first(stream))
#   ramp_len = inseconds(len)
#   ramp = asstream(sample_rate=sample_rate) do t
#     t < ramp_len ? -0.5cos(π*(t/ustrip(ramp_len)))+0.5 : 1
#   end
#   stream_len = size(first(stream),1)
#   num_units = ceil(Int,insamples(ramp_len,sample_rate) / stream_len)
#   mult(stream,take(ramp,num_units))
# end


function rampon{R}(x::Sound{R},len=5ms)
  ramp_len = insamples(len,R*Hz)
	@assert size(x,1) > ramp_len

	ramp_t = (1.0:ramp_len) / ramp_len
	up = -0.5cos(π*ramp_t)+0.5
	envelope = [up; ones(size(x,1) - ramp_len)]
	mult(x,envelope)
end


# """
#     rampoff(stream,[len=5ms],[after=0s])

# Applies a half consine ramp to the end of the sound.

# For streams, you may specify that the ramp off occur some number of seconds
# after the start of the stream.
# """
# function rampoff(itr,len=5ms,after=0s)
#   sample_rate=samplerate(first(itr))
#   stream_len = size(first(itr),1)
#   ramp = asstream(sample_rate=sample_rate) do t
#     if t < after
#       1
#     elseif after <= t < after+len
#       -0.5cos(π*(t - after)/ustrip(len) + π)+0.5)
#     else
#       0
#     end
#   end
#   num_units = ceil(Int,insamples(after+len,sample_rate) / stream_len)
#   take(mult(itr,ramp),num_units)
# end

function rampoff{R}(x::Sound{R},len=5ms)
  ramp_len = insamples(len,R*Hz)
  @assert size(x,1) > ramp_len

  ramp_t = (1.0:ramp_len) / ramp_len
	down = -0.5cos(π*ramp_t+π)+0.5
  envelope = [ones(size(x,1) - ramp_len); down]
  mult(x,envelope)
end

"""
    attenuate(x,atten_dB)

Apply the given decibels of attenuation to the sound (or stream) relative to a
power level of 1.

This function normalizes the sound to have a root mean squared value of 1 and
then reduces the sound by a factor of ``10^{-a/20}``, where ``a`` = `atten_dB`.

If `x` is a stream, attenuate takes an additional keyword argument
`time_constant`. This determines the time across which the sound is
normalized to power 1, which defaults to 1 second.
"""
function attenuate(x::Sound,atten_dB)
	10^(-atten_dB/20) * x/sqrt(mean(x.^2))
end

# immutable AttenStream{T}
#   itr::T
#   atten_dB::Float64
#   decay::Float64
# end

# immutable AttenState{T}
#   itr_state::T
#   μ²::Float64
#   N::Float64
# end
# show(io::IO,as::AttenStream) = write(io,"AttenStream(...,$(as.atten_dB),$(as.decay))")
# start{T}(as::AttenStream{T}) = AttenState(start(as.itr),1.0,1.0)
# done(as::AttenStream,s::AttenState) = done(as.itr,s.itr_state)
# function next{T,S}(as::AttenStream{T},s::AttenState{S})
#   xs, itr_state = next(as.itr,s.itr_state)
#   ys = similar(xs)
#   for i in 1:size(xs,1)
#     ys[i,:] = 10^(-as.atten_dB/20) * xs[i,:] ./ sqrt(s.μ² ./ s.N)
#     s = AttenState(itr_state,as.decay*s.μ² + mean(xs[i,:])^2,as.decay*s.N + 1)
#   end

#   ys, s
# end

# function attenuate(itr,atten_dB=20;time_constant=1)
#   sr = samplerate(first(itr))
#   AttenStream(itr,float(atten_dB),1 - 1 / (time_constant*sr))
# end

const default_sample_rate = 44100Hz

type SoundSetupState
  samplerate::Freq{Int}
  playing::Dict{Sound,Float64}
  state::Ptr{Void}
  num_channels::Int
  queue_size::Int
  stream_unit::Int
end
const default_stream_unit = 2^11
const sound_setup_state = SoundSetupState(0Hz,Dict(),C_NULL,0,0,default_stream_unit)
isready(s::SoundSetupState) = s.samplerate != 0Hz

"""
    stream_unit()

Report the length in samples of each unit that all sound streams should generate.
"""
stream_unit(s::SoundSetupState=sound_setup_state) = s.stream_unit

"""
    samplerate([sound])

Report the sampling rate of the sound or of any object
that can be turned into a sound.

With no argument this reports the current playback sample rate, as defined by
[`setup_sound`](@ref).

The sampling rate of an object determines how many samples per second are used
to represent the sound. Objects that can be converted to sounds are assumed to
be at the sampling rate of the current hardware settings as defined by
[`setup_sound`](@ref).
"""
samplerate(x::Vector) = samplerate()
samplerate(x::Matrix) = samplerate()
function samplerate(s::SoundSetupState=sound_setup_state)
  if s.samplerate == 0Hz
    default_sample_rate
  else
    s.samplerate
  end
end

# Give some time after the sound stops playing to clean it up.
# This ensures that even when there is some latency
# the sound will not be GC'ed until it is done playing.
const sound_cleanup_wait = 2

# register_sound: ensures that sounds are not GC'ed while they are
# playing. Whenever a new sound is registered it removes sounds that are no
# longer playing. This is called internally by all methods that send requests to
# play sounds to the weber-sound library (implemented in weber_sound.c)
function register_sound(current::Sound,done_at::Float64)
  setstate = sound_setup_state
  setstate.playing[current] = done_at
  for s in keys(setstate.playing)
    done_at = setstate.playing[s]
    if done_at > Weber.tick() + sound_cleanup_wait
      delete!(setstate.playing,s)
    end
  end
end

function ws_if_error(msg)
  if sound_setup_state.state != C_NULL
    str = unsafe_string(ccall((:ws_error_str,weber_sound),Cstring,
                              (Ptr{Void},),sound_setup_state.state))
    if !isempty(str) error(msg*" - "*str) end

    str = unsafe_string(ccall((:ws_warn_str,weber_sound),Cstring,
                              (Ptr{Void},),sound_setup_state.state))
    if !isempty(str) && show_latency_warnings()
      warn(msg*" - "*str*moment_trace_string())
    end
  end
end

"""
    setup_sound(;[sample_rate=samplerate()],[num_channels=8],[queue_size=8],
                [stream_unit=2^11])

Initialize format and capacity of audio playback.

This function is called automatically (using the default settings) the first
time a `Sound` object is created (normally during [`play`](@ref) or
[`stream`](@ref)).  It need not normally be called explicitly, unless you wish
to change one of the default settings.

# Sample Rate

Sample rate determines the maximum playable frequency (max freq is ≈
sample_rate/2). Changing the sample rate from the default 44100 to a new value
will also change the default sample rate sounds will be created at, to match
this new sample rate.

# Channel Number

The number of channels determines the number of sounds and streams that can be
played concurrently. Note that discrete sounds and streams use a distinct set of
channels.

# Queue Size

Sounds can be queued to play ahead of time (using the `time` parameter of
[`play`](@ref)). When you request that a sound be played it may be queued to
play on a channel where a sound is already playing. The number of sounds that
can be queued to play at once is determined by queue size. The number of
channels times the queue size determines the number of sounds that you can queue
up to play ahead of time.

# Stream Unit

The stream unit determines the number of samples that are streamed at one time.
Iterators to be used as streams should generate this many samples at a time.  If
this value is too small for your hardware, streams will sound jumpy. However the
latency of streams will increase as the stream unit increases. Future versions
of Weber will likely improve the latency of stream playback.

"""
function setup_sound(;sample_rate=samplerate(),
                     buffer_size=nothing,queue_size=8,num_channels=8,
                     stream_unit=default_stream_unit)
  sample_rate_Hz = inHz(Int,sample_rate)
  empty!(sound_cache)

  if isready(sound_setup_state)
    ccall((:ws_close,weber_sound),Void,(Ptr{Void},),sound_setup_state.state)
    ws_if_error("While closing old audio stream during setup")
    ccall((:ws_free,weber_sound),Void,(Ptr{Void},),sound_setup_state.state)
  else

    if !weber_sound_is_setup[]
      weber_sound_is_setup[] = true
      atexit() do
        sleep(0.1)
        ccall((:ws_close,weber_sound),Void,
              (Ptr{Void},),sound_setup_state.state)
        ws_if_error("While closing audio stream at exit.")
        ccall((:ws_free,weber_sound),Void,
              (Ptr{Void},),sound_setup_state.state)
      end
    end
  end
  if samplerate() != sample_rate_Hz
    warn(cleanstr("The sample rate is being changed from "*
         "$(samplerate()) to $(sample_rate_Hz)"*
         "Sounds you've created that do not share this new sample rate may "*
         "not play correctly."))
  end

  sound_setup_state.samplerate = sample_rate_Hz
  sound_setup_state.state = ccall((:ws_setup,weber_sound),Ptr{Void},
                                  (Cint,Cint,Cint,),ustrip(sample_rate_Hz),
                                  num_channels,queue_size)
  sound_setup_state.num_channels = num_channels
  sound_setup_state.queue_size = queue_size
  sound_setup_state.stream_unit = stream_unit
  ws_if_error("While trying to initialize sound")
end

"""
    current_sound_latency()

Reports the current, minimum latency of audio playback.

The current latency depends on your hardware and software drivers. This
estimate does not include the time it takes for a sound to travel from
your sound card to speakers or headphones. This latency estimate is used
internally by [`play`](@ref) to present sounds at accurate times.
"""
function current_sound_latency()
  ccall((:ws_cur_latency,weber_sound),Cdouble,
        (Ptr{Void},),sound_setup_state.state)
end

"""
    play(x;[time=0.0],[channel=0])

Plays a sound (created via [`sound`](@ref)).

For convenience, play can also can be called on any object that can be turned
into a sound (via `sound`).

This function returns immediately with the channel the sound is playing on. You
may provide a specific channel that the sound plays on: only one sound can be
played per channel. Normally it is unecessary to specify a channel, because an
appropriate channel is selected for you. However, pausing and resuming of
sounds occurs on a per channel basis, so if you plan to pause a specific
sound, you can do so by specifying its channel.

If `time > 0`, the sound plays at the given time (in seconds from epoch, or
seconds from experiment start if an experiment is running), otherwise the sound
plays as close to right now as is possible.
"""
function play(x;time=0.0,channel=0)
  if !isready(sound_setup_state)
    setup_sound()
  end

  if in_experiment() && !experiment_running()
    error("You cannot call `play` during experiment `setup`. During `setup`",
          " you should add play to a trial (e.g. ",
          "`addtrial(moment(play,my_sound))`).")
  end
  warn("Calling play outside of an experiment moment.")
  _play(x,time,channel)
end

function _play(x,time=0.0,channel=0)
  play(sound(x),time,channel)
end

immutable WS_Sound
  buffer::Ptr{Void}
  len::Cint
end

function play{R}(x::Sound{R,Q0f15,2},time::Float64=0.0,channel::Int=0)
  if R != ustrip(samplerate())
    error("Sample rate of sound ($(R*Hz)) and audio playback ($(samplerate()))",
          " do not match. Please resample this sound by calling `resample` ",
          "or `sound`.")
  end
  if !(1 <= channel <= sound_setup_state.num_channels || channel <= 0)
    error("Channel $channel does not exist. Must fall between 1 and",
          " $(sound_setup_state.num_channels)")
  end

  # first, verify the sound can be played when we want to
  if time > 0.0
    latency = current_sound_latency()
    now = Weber.tick()
    if now + latency > time && show_latency_warnings()
      if latency > 0
        warn("Requested timing of sound cannot be achieved. ",
             "With your hardware you cannot request the playback of a sound ",
             "< $(round(1000*latency,2))ms before it begins.",
             moment_trace_string())
      else
        warn("Requested timing of sound cannot be achieved. ",
             "Give more time for the sound to be played.",
             moment_trace_string())
      end
      if experiment_running()
        record("high_latency",value=(now + latency) - time)
      end
    end
  elseif experiment_running() && show_latency_warnings()
    warn("Cannot guarantee the timing of a sound. Add a delay before playing the",
         " sound if precise timing is required.",moment_trace_string())
  end

  # play the sound
  channel = ccall((:ws_play,weber_sound),Cint,
                  (Cdouble,Cdouble,Cint,Ref{WS_Sound},Ptr{Void}),
                  Weber.tick(),time,channel-1,
                  WS_Sound(pointer(x.data),size(x,1)),
                  sound_setup_state.state) + 1
  ws_if_error("While playing sound")
  register_sound(x,(time > 0.0 ? time : Weber.tick()) + ustrip(duration(x)))

  channel
end

type Streamer
  next_stream::Float64
  channel::Int
  itr_state
  itr
end
show(stream::IO,streamer::Streamer) =
  write(stream,"<Streamer channel: $(streamer.channel)>")

# function setup_streamers()
#   streamers[-1] = Streamer(0.0,0,nothing,nothing)
#   Timer(1/60,1/60) do timer
#     for streamer in values(streamers)
#       if streamer.itr != nothing
#         process(streamer)
#       end
#     end
#   end
# end

# const num_channels = 8
# const streamers = Dict{Int,Streamer}()
# """
#     stream([itr | fn],channel=1)

# Plays sounds continuously on a given channel by reading from the iterator `itr`
# whenever more data is required. The iterator should return objects that can be
# turned into sounds (via [`sound`](@ref)). The number of available streaming
# channels is determined by [`setup_sound`](@ref). The size, in samples, of each
# sound returned by this iterator should be equal to [`stream_unit`](@ref).

# Alternatively a `fn` can be streamed: this transforms a previously streamed itr
# into a new iterator by calling `fn(itr)`. If no stream already exists on the
# given channel, `fn` is passed the result of `countfrom()`.

# A stream stops playing if the iterator is finished. There can only be one stream
# per channel.  Streaming a new iterator on the same channel as another stream
# stops the older stream. The channels for `stream` are separate from the channels
# for `play`. That is, `play(mysound,channel=1)` plays a sound on a channel
# separate from `stream(mystream,1)`.

# !!! warning "Streams are not precisely timed"

#     Streams cannot occur at a precise time. Their latency is variable and
#     depends on the value of `stream_unit()`. Future versions of Weber will
#     likely allow for precisely timed audio streams.

# """

# function stream(itr,channel::Int=1)
#   !isready(sound_setup_state) ? setup_sound() : nothing
#   @assert 1 <= channel <= sound_setup_state.num_channels
#   itr_state = start(itr)
#   stop(channel)

#   if in_experiment()
#     data(get_experiment()).streamers[channel] =
#       Streamer(tick(),channel,itr_state,itr)
#   else
#     if isempty(streamers)
#       setup_streamers()
#     end
#     streamers[channel] = Streamer(tick(),channel,itr_state,itr)
#   end
# end

# function stream(fn::Function,channel::Int)
#   !isready(sound_setup_state) ? setup_sound() : nothing
#   @assert 1 <= channel <= sound_setup_state.num_channels
#   dict = in_experiment() ? data(get_experiment()).streamers : streamers
#   itr = if channel in keys(dict)
#     streamer = dict[channel]
#     delete!(dict,channel)
#     rest(streamer.itr,streamer.itr_state)
#   else
#     countfrom()
#   end

#   stream(fn(itr),channel)
# end

# """
#     fadeto(stream,channel=1,transition=0.05)

# Smoothly transition from the currently playing stream to another stream.
# """
# function fadeto(new,channel::Int=1,transition=0.05)
#   stream(channel) do old
#     if isa(first(old),Number)
#       rampon(new,transition)
#     else
#       mix(rampoff(old,transition),rampon(new,transition))
#     end
#   end
# end

"""
    fadeto(sound1,sound2,overlap=0.05)

A smooth transition from sound1 to sound2, overlapping the end of sound1
and the start of sound2 by `overlap` (in seconds).
"""
function fadeto{R}(a::Sound{R},b::Sound{R},overlap=50ms)
  mix(rampoff(a,overlap),
      [silence(duration(a) - overlap); rampon(b,overlap)])
end

"""
    stop(channel)

Stop the stream that is playing on the given channel.
"""
function stop(channel::Int)
  @assert 1 <= channel <= sound_setup_state.num_channels
  if in_experiment()
    delete!(data(get_experiment()).streamers,channel)
  else
    delete!(streamers,channel)
  end
  nothing
end

function process(streamer::Streamer)
  nothing
end

#   if !done(streamer.itr,streamer.itr_state)
#     obj, next_state = next(streamer.itr,streamer.itr_state)
#     x = sound(obj,false)
#     @assert samplerate(x) == samplerate()

#     done_at = -1.0

#     done_at = ccall((:ws_play_next,weber_sound),Cdouble,
#                     (Cdouble,Cint,Ref{WS_Sound},Ptr{Void}),
#                     tick(),streamer.channel-1,x.chunk,
#                     sound_setup_state.state)
#     ws_if_error("While playing sound")
#     if done_at < 0
#       # sound not ready to be queued for playing, wait a bit and try again
#       streamer.next_stream += 0.05duration(x)
#     else
#       # sound was queued to play, wait until this queued sound actually
#       # starts playing to queue the next stream unit
#       register_sound(x,done_at)
#       streamer.next_stream += 0.75duration(x)
#       streamer.itr_state = next_state
#     end
#   else stop(streamer.channel) end
# end

"""
    play(fn::Function)

Play the sound that's returned by calling `fn`.
"""
function play(fn::Function;keys...)
  play(fn();keys...)
end

"""
    pause_sounds([channel],[isstream])

Pause all sounds (or a stream) playing on a given channel.

If no channel is specified, then all sounds are paused.
"""
function pause_sounds(channel=-1,isstream=false)
  if isready(sound_setup_state)
    @assert 1 <= channel <= sound_setup_state.num_channels || channel <= 0
    ccall((:ws_pause,weber_sound),Void,(Ptr{Void},Cint,Cint,Cint),
          sound_setup_state.state,channel-1,isstream,true)
    ws_if_error("While pausing sounds")
  end
end

"""
    resume_sounds([channel],[isstream])

Resume all sounds (or a stream) playing on a given channel.

If no channel is specified, then all sounds are resumed.
"""
function resume_sounds(channel=-1,isstream=false)
  if isready(sound_setup_state)
    @assert 1 <= channel <= sound_setup_state.num_channels || channel <= 0
    ccall((:ws_pause,weber_sound),Void,(Ptr{Void},Cint,Cint,Cint),
        sound_setup_state.state,channel-1,isstream,false)
    ws_if_error("While resuming audio playback")
  end
end
