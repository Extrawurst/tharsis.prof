//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/** A 'chunky' event list that supports real-time adding of profiling data and related
 * ranges/generators. */
module tharsis.prof.chunkyeventlist;



import std.algorithm;
import std.array;
import std.stdio;

import tharsis.prof.event;
import tharsis.prof.profiler;
import tharsis.prof.ranges;


/** A list of events providing range 'slices', using chunks of profiling data for storage.
 *
 * Useful for real-time profiling (used by Despiker); can add new chunks of profile data
 * in real time and create ranges to generate events in specified time or chunk slices
 * without processing the preceding chunks.
 */
struct ChunkyEventList
{
    /** A single chunk of profiling data.
     *
     * Public so the user can allocate chunks for ChunkyEventList storage.
     */
    struct Chunk
    {
    private:
        /// Start time of the last event in the chunk.
        ulong lastStartTime;
        /// Raw profile data.
        immutable(ubyte)[] data;

        /// Get the start time of the first event in the chunk.
        ulong startTime() @safe pure nothrow const @nogc
        {
            return EventRange(data).front.time;
        }
    }

    /** Generates events from the event list as chunks are added.
     *
     * Range is not useful here, since it would either have to be 'empty' after consuming
     * events from existing chunks even though more chunks may be added, or block in
     * popFront(), which would only make it usable from separate threads/fibers.
     */
    struct Generator
    {
        /** A profile event generated by Generator.
         *
         * This is a tharsis.prof.Event with some extra data to generate SliceExtents for
         * zones generated from GeneratedEvents.
         */
        struct GeneratedEvent
        {
        private:
            /// Chunk the event is in.
            uint chunk;
            /// The first byte of the event in the chunk.
            uint startByte;
            /// The first byte *after* the event in the chunk.
            uint endByte;

        public:
            /// Profiling event itself.
            Event event;

            // Make GeneratedEvent usable as an Event.
            alias event this;
        }

    private:
        /// The chunky event list we are generating events from.
        const(ChunkyEventList)* events_;
        /// Index of the current chunk in events_.
        int chunkIndex_;
        /// Position of the current event in the current chunk.
        uint eventPos_ = 0;
        /// Event range generating events from the current chunk.
        EventRange currentChunkEvents_;

    public:
        /** Construct a Generator.
         *
         * Params:
         *
         * events = Chunky event list to generate events from.
         */
        this(const(ChunkyEventList)* events) @safe pure nothrow @nogc
        {
            events_ = events;
            // If no chunks yet, set 'chunk index' to -1 so we can 'move to the next
            // chunk' in generate() once there are chunks.
            if(events_.chunks_.empty)
            {
                chunkIndex_ = -1;
                currentChunkEvents_ = EventRange([]);
            }
            // If there already are chunks, use the first one.
            else
            {
                chunkIndex_ = 0;
                currentChunkEvents_ = EventRange(events_.chunks_[0].data);
            }
        }

        /** Try to generate the next event.
         *
         * Params:
         *
         * event = The event will be written here, if generated.
         *
         * Returns: true if an event was generated, false otherwise (all chunks that
         *          have been added to the event list so far have been spent).
         */
        bool generate(out GeneratedEvent event) @safe pure nothrow @nogc
        {
            // Done reading current chunk, move to the next one, if any.
            if(currentChunkEvents_.empty)
            {
                // At the end of the last chunk in the list so far.
                if(chunkIndex_ >= cast(int)events_.chunks_.length - 1) { return false; }

                // There are more chunks, so move to the next.
                ++chunkIndex_;
                currentChunkEvents_ = EventRange(events_.chunks_[chunkIndex_].data);
                eventPos_ = 0;
            }

            // Generate the event.
            event.event     = currentChunkEvents_.front;
            event.chunk     = chunkIndex_;
            event.startByte = eventPos_;

            // End pos of the current event, i.e. start pos of the next event.
            const allBytes = events_.chunks_[chunkIndex_].data.length;
            eventPos_ = cast(uint)(allBytes - currentChunkEvents_.bytesLeft);

            event.endByte = eventPos_;

            currentChunkEvents_.popFront();
            return true;
        }
    }


    /** A 'slice' of events in the chunky event list.
     *
     * Produced by ChunkyEventList.slice() from SliceExtents. SliceExtents are currently
     * generated only by ChunkyZoneGenerator, which creates exact slices for generated
     * zones.
     *
     * Unlike TimeSlice, which is a slice of all events in specified time, Slice is more
     * precise; it starts and ends at specific events (TimeSlice includes any events in
     * specified time, even if multiple events have occured the same time, which can cause
     * issues with zones when a time slice for a zone includes the zone end event for the
     * previous zone, which may have ended in the same hectonanosecond as the new zone).
     */
    struct Slice
    {
    private:
        // All chunks in the ChunkyEventList.
        const(Chunk)[] chunks_;
        // Extents of this slice (start/end chunk/byte).
        SliceExtents extents_;

        /* Range over events in the current chunk.
         *
         * Once this is empty, the slice is empty (popFront() immediately replaces the
         * range if emptied while we still have more chunks).
         */
        EventRange currentChunkEvents_;

        // Index of the current chunks in chunks_.
        uint currentChunk_;

        import std.traits;
        import std.range;
        // Must be a forward range of Event.
        static assert(isForwardRange!Slice,
                      "ChunkyEventList.Slice must be a forward range");
        static assert(is(Unqual!(ElementType!Slice) == Event),
                        "ChunkyEventList.Slice must be a range of Event");

        /* Construct a Slice.
         *
         * Params:
         *
         * chunks = All chunks in the ChunkyEventList.
         * slice  = Extents of the slice (start/end chunk/byte).
         */
        this(const(Chunk)[] chunks, SliceExtents slice) @safe pure nothrow @nogc
        {
            assert(slice.isValid, "Invalid slice in Slice constructor");

            chunks_       = chunks;
            extents_      = slice;
            currentChunk_ = extents_.firstChunk;

            // Must start at chunk start instead of first event pos to ensure any
            // checkpoint event at the start of the chunk is read - to ensure event times
            // are correct.
            currentChunkEvents_ = EventRange(chunks_[currentChunk_].data);
            const currentChunkLength = chunks_[currentChunk_].data.length;

            for(;;)
            {
                const eventEnd = currentChunkLength - currentChunkEvents_.bytesLeft;
                // If current event is after first event position, we reached the first event.
                if(eventEnd > extents_.firstEventStart) { break; }
                currentChunkEvents_.popFront();
            }
        }

    public:
        /// Get the event on front of the slice.
        Event front() @safe pure nothrow const @nogc
        {
            assert(!empty, "Can't get front of an empty range");
            return currentChunkEvents_.front();
        }

        /// Move to the next event.
        void popFront() @safe pure nothrow @nogc
        {
            assert(!empty, "Can't pop front of an empty range");
            currentChunkEvents_.popFront();

            // If ran out of events in current chunk, move to the next one.
            if(currentChunkEvents_.empty)
            {
                // Ran out of chunks; the Range is now empty.
                if(currentChunk_ == extents_.lastChunk) { return; }

                ++currentChunk_;
                currentChunkEvents_ = EventRange(chunks_[currentChunk_].data);
            }

            // If we're in the last chunk (or if the last event was at the end of the
            // last chunk, in which case we've moved into the one after the last).
            if(currentChunk_ >= extents_.lastChunk)
            {
                // If the last popFront()/range replacement 
                const eventEnd =
                    chunks_[currentChunk_].data.length - currentChunkEvents_.bytesLeft;
                // If we're behind the last chunk, or still in the last chunk but have
                // reached an event that ends after the last event in extents ends, we're
                // at the end of the Slice, so make currentChunkEvents_ empty.
                if(currentChunk_ > extents_.lastChunk || eventEnd > extents_.lastEventEnd)
                {
                    currentChunkEvents_ = EventRange([]);
                }
            }
        }

        /// Is the slice empty?
        bool empty() @safe pure nothrow const @nogc { return currentChunkEvents_.empty; }


        // Must be a property, isForwardRange won't work otherwise.
        /// Get a copy of the slice in its current state.
        @property Slice save() @safe pure nothrow const @nogc { return this; }
    }


    /** A 'slice' of events based on start end end time.
     *
     * Produced by ChunkyEventList.timeSlice().
     *
     * TimeSlice is useful to get events in specified time extents but may be useless
     * for zone generation as it may contain zone end events for zones that started before
     * the slice. Even if a time slice starting exactly at a zone start time is used, a
     * preceding zone may have ended in the same hectonanosecond.
     */
    struct TimeSlice
    {
    private:
        // Chunks remaining in the range, not including the chunk used in currentChunkEvents_.
        const(Chunk)[] chunksLeft_;

        // Range over events in the current chunk. If empty, the TimeSlice is empty.
        EventRange currentChunkEvents_;

        // Start time of the slice in hectonanosecond.
        ulong start_;
        // End time of the slice in hectonanosecond.
        ulong end_;

        import std.traits;
        import std.range;
        // Must be a ForwardRange of Event.
        static assert(isForwardRange!TimeSlice, 
                      "ChunkyEventList.TimeSlice must be a forward range");
        static assert(is(Unqual!(ElementType!TimeSlice) == Event),
                        "ChunkyEventList.TimeSlice must be a range of Event");

        /** Construct a TimeSlice.
         *
         * Params:
         *
         * chunks = All chunks in the ChunkyEventList.
         * start  = Start time of the slice in hectonanoseconds.
         * end    = End time of the slice in hectonanoseconds.
         */
        this(const(Chunk)[] chunks, ulong start, ulong end) @safe pure nothrow @nogc
        {
            // Events starting at start time are included, events ending at end time are not.
            while(!chunks.empty && chunks.front.lastStartTime < start) { chunks.popFront; }
            while(!chunks.empty && chunks.back.startTime > end)        { chunks.popBack; }

            chunksLeft_ = chunks;
            start_      = start;
            end_        = end;

            if(chunksLeft_.empty)
            {
                currentChunkEvents_ = EventRange([]);
                return;
            }

            // Get an event range for the current chunk and forget the chunk.
            currentChunkEvents_ = EventRange(chunksLeft_.front.data);
            chunksLeft_.popFront();
            // Move to the first event in the current chunk.
            while(currentChunkEvents_.front.time < start)
            {
                currentChunkEvents_.popFront;
            }
        }

    public:
        /// Get the event on front of the slice.
        Event front() @safe pure nothrow const @nogc
        {
            assert(!empty, "Can't get front of an empty range");
            return currentChunkEvents_.front();
        }

        /// Move to the next event.
        void popFront() @safe pure nothrow @nogc
        {
            assert(!empty, "Can't pop front of an empty range");

            currentChunkEvents_.popFront();

            if(currentChunkEvents_.empty)
            {
                // Ran out of chunks; the TimeSlice is now empty.
                if(chunksLeft_.empty) { return; }

                currentChunkEvents_ = EventRange(chunksLeft_.front.data);
                chunksLeft_.popFront();
            }

            if(currentChunkEvents_.front.time >= end_)
            {
                // Ran out of events in our time slice; make currentChunkEvents_ empty.
                currentChunkEvents_ = EventRange([]);
            }
        }

        /// Is the slice empty?
        bool empty() @safe pure nothrow const @nogc
        {
            return currentChunkEvents_.empty;
        }

        // Must be a property, isForwardRange won't work otherwise.
        /// Get a copy of the range in its current state.
        @property TimeSlice save() @safe pure nothrow const @nogc { return this; }
    }

    /// Extents of a Slice.
    struct SliceExtents
    {
    private:
        /// Index of the chunk containing the first event in the slice.
        uint firstChunk;
        /// Index of the byte in the first chunk where the first event starts.
        uint firstEventStart;

        /// Index of the chunk containing the last event in the slice.
        uint lastChunk;
        /// Index of the byte in the last chunk right after the last event ends.
        uint lastEventEnd;

        /** Are the SliceExtents valid?
         *
         * First chunk must be <= last chunk and the extents must not be empty.
         */
        bool isValid() @safe pure nothrow const @nogc
        {
            return firstChunk <= lastChunk &&
                   (firstChunk != lastChunk || firstEventStart < lastEventEnd);
        }
    }

private:
    /** Storage for chunks (chunk slices, not chunk data itself).
     *
     * Passed by constructor or provideStorage(). Never reallocated internally.
     */
    Chunk[] chunkStorage_;

    /// A slice of chunkStorage_ that contains actually used chunks.
    Chunk[] chunks_;

public:
    /** Construct a ChunkyEventList.
     *
     * Params:
     *
     * chunkStorage = Space allocated for profile data chunks (not chunk data itself).
     *                outOfSpace() must be called before adding chunks to determine if
     *                this space has been spent, and provideStorage() must be called
     *                to allocate more chunks after running out of space. ChunkyEventList
     *                never allocates by itself.
     */
    this(Chunk[] chunkStorage) @safe pure nothrow @nogc
    {
        chunkStorage_ = chunkStorage;
    }

    /** Is the ChunkyEventList out of space?
     *
     * If true, more chunk storage must be provided by calling provideStorage().
     */
    bool outOfSpace() @safe pure nothrow const @nogc
    {
        return chunks_.length >= chunkStorage_.length;
    }

    /** Provide more space to store chunks (not chunk data itself).
     *
     * Must be called when outOfSpace() returns true. Must provide more space than the
     * preceding provideStorage() or constructor call.
     */
    void provideStorage(Chunk[] storage) @safe pure nothrow @nogc
    {
        assert(storage.length >= chunks_.length,
               "provideStorage does not provide enough space for existing chunks");

        chunkStorage_ = storage;
        chunkStorage_[0 .. chunks_.length] = chunks_[];
        chunks_ = chunkStorage_[0 .. chunks_.length];
    }

    /// Get a generator to produce profiling events from the list over time as chunks are added.
    Generator generator() @safe pure nothrow const @nogc
    {
        return Generator(&this);
    }

    /** Add a new chunk of profile data.
     *
     * Params:
     *
     * data = Chunk of data to add. Note that the first event in the chunk must have
     *        higher time value for the chunk to be added (false will be returned on
     *        error). This can be ensured by emitting a checkpoint event with the Profiler
     *        that produces the chunk before any other events in the chunk. Also note that
     *        data $(B must not) be deallocated for as long as the ChunkyEventList exists;
     *        the ChunkyEventList will use data directly instead of creating a copy.
     *
     * Returns: true on success, false if the first event in the chunk didn't occur in
     *          time after the last event already in the list.
     */
    bool addChunk(immutable(ubyte)[] data) @safe pure nothrow @nogc
    {
        assert(!data.empty, "Can't add an empty chunk of profiling data");
        assert(chunks_.length < chunkStorage_.length, "Out of chunk space");

        // Get the start time of the last event in the chunk.
        ulong lastStartTime;
        foreach(event; EventRange(data)) { lastStartTime = event.time; }

        auto newChunk = Chunk(lastStartTime, data);

        // New chunk must start at or after the end of the last chunk.
        if(!chunks_.empty && newChunk.startTime < chunks_.back.lastStartTime) { return false; }
        chunkStorage_[chunks_.length] = newChunk;
        chunks_ = chunkStorage_[0 .. chunks_.length + 1];
        return true;
    }

    /** Get an exact slice of the ChunkyEventList as described by a SliceExtents instance.
     *
     * SliceExtents is currently only generated by the ChunkyZoneGenerator to allow
     * getting exact slices containing only the events in any single zone, as opposed to
     * all events that occured at the time of that zone (e.g. an end of a preceding zone
     * that occured in the same hectonanosecond a new zone started in).
     */
    Slice slice(SliceExtents slice) @safe pure nothrow const @nogc
    {
        return Slice(chunks_, slice);
    }

    /** Get a slice of the ChunkyEventList containing events in specified time range.
     *
     * Params:
     *
     * start = Start of the time slice. Events occuring at this time will be included.
     * end   = End of the time slice. Events occuring at this time will $(D not) be included.
     */
    TimeSlice timeSlice(ulong start, ulong end) @safe pure nothrow const @nogc
    {
        return TimeSlice(chunks_, start, end);
    }
}
unittest
{
    writeln("ChunkyEventList unittest");
    scope(success) { writeln("ChunkyEventList unittest SUCCESS"); }
    scope(failure) { writeln("ChunkyEventList unittest FAILURE"); }

    const frameCount = 16;

    import std.typecons;
    auto profiler = scoped!Profiler(new ubyte[Profiler.maxEventBytes + 2048]);
    auto chunkyEvents = ChunkyEventList(new ChunkyEventList.Chunk[frameCount + 1]);

    size_t lastChunkEnd = 0;
    profiler.checkpointEvent();
    // std.typecons.scoped! stores the Profiler on the stack.
    // Simulate 16 'frames'
    foreach(frame; 0 .. frameCount)
    {
        Zone topLevel = Zone(profiler, "frame");

        // Simulate frame overhead. Replace this with your frame code.
        {
            Zone nested1 = Zone(profiler, "frameStart");
            foreach(i; 0 .. 1000) { continue; }
        }
        {
            Zone nested2 = Zone(profiler, "frameCore");
            foreach(i; 0 .. 10000) { continue; }
        }

        if(!chunkyEvents.addChunk(profiler.profileData[lastChunkEnd .. $].idup))
        {
            assert(false);
        }
        lastChunkEnd = profiler.profileData.length;
        profiler.checkpointEvent();
    }

    // Chunk for the last checkpoint/zone end.
    if(!chunkyEvents.addChunk(profiler.profileData[lastChunkEnd .. $].idup))
    {
        assert(false);
    }

    // Ensure a slice of all events in chunkyEvents contains all events.
    assert(EventRange(profiler.profileData).equal(chunkyEvents.timeSlice(0, ulong.max)));

    // Ensure events in a time slice actually are in that time slice.
    foreach(event; chunkyEvents.timeSlice(1000, 3000))
    {
        assert(event.time >= 1000 && event.time < 3000);
    }
}

/// Readability alias.
alias ChunkyEventGenerator = ChunkyEventList.Generator;
/// Readability alias.
alias ChunkyEventSlice = ChunkyEventList.Slice;


/** Generates zones from a ChunkyEventList as chunks are added.
 *
 * Range is not useful here, since it would either have to be 'empty' after consuming
 * zones from existing chunks even though more chunks may be added, or block in
 * popFront(), which would only make it usable from separate threads/fibers.
 */
struct ChunkyZoneGenerator
{
    /// ZoneData extended with ChunkyEventList slice extents to regenerate events in the zone.
    struct GeneratedZoneData
    {
        /** ChunkyEventList extents of all events used to produce this zone.
         *
         * Allows to slice the ChunkyEventList to reproduce the zone and its children.
         */
        ChunkyEventList.SliceExtents extents;

        /// The zone data itself.
        ZoneData zoneData;
        alias zoneData this;
    }

private:
    /** ZoneInfo extended with information about the chunk and byte containing the first event.
     *
     * Needed to initialize the SliceExtents in GeneratedZoneData.
     */
    struct ExtendedZoneInfo
    {
        // Chunk containing the first event in the zone (its zone start event).
        uint firstChunk;
        // First byte of the first event in firstChunk.
        uint startByte;

        // Generated zone info itself.
        ZoneInfo zoneInfo;

        // Use ExtendedZoneInfo as ZoneInfo.
        alias zoneInfo this;
    }

    // Generates profiling events as chunks are added.
    ChunkyEventGenerator events_;

    // Stack of ZoneInfo describing the current zone and all its parents.
    //
    // The current zone can be found at zoneStack_[zoneStackDepth_ - 1], its parent
    // at zoneStack_[zoneStackDepth_ - 2], etc.
    ExtendedZoneInfo[maxStackDepth] zoneStack_;

    // Depth of the zone stack at the moment.
    size_t zoneStackDepth_ = 0;

    // ID of the next zone.
    uint nextID_ = 1;

public:
    /** Construct a ChunkyZoneRange.
     *
     * Params:
     *
     * eventList = Chunky event generator (returned by ChunkyEventList.generator()) to
     *             produce events to generate zones from.
     */
    this(ChunkyEventGenerator events) @safe pure nothrow @nogc
    {
        events_ = events;
    }

    /** Try to generate the next zone.
     *
     * Params:
     *
     * zone = The zone will be written here, if generated.
     *
     * Returns: true if an zone was generated, false otherwise (all chunks that have been
     *          added to the event list so far have been spent).
     */
    bool generate(out GeneratedZoneData zone) @safe pure nothrow @nogc
    {
        events_.GeneratedEvent event;
        while(events_.generate(event))
        {
            alias stack = zoneStack_;
            alias depth = zoneStackDepth_;
            with(EventID) final switch(event.id)
            {
                case Checkpoint, Variable: break;
                case ZoneStart:
                    assert(zoneStackDepth_ < maxStackDepth,
                           "Zone nesting too deep; zone stack overflow.");
                    const zoneInfo = ZoneInfo(nextID_++, event.time);
                    stack[depth++] = ExtendedZoneInfo(event.chunk, event.startByte, zoneInfo);
                    break;
                case ZoneEnd:
                    zone.zoneData = buildZoneData(stack[0 .. depth], event.time);
                    ExtendedZoneInfo info = stack[depth - 1];
                    alias Extents = ChunkyEventList.SliceExtents;
                    zone.extents = Extents(info.firstChunk, info.startByte,
                                           event.chunk, event.endByte);
                    --depth;
                    return true;
                // If an info event has the same start time as the current zone, it's info
                // about the current zone.
                case Info:
                    auto curZone = &stack[depth - 1];
                    if(event.time == curZone.startTime) { curZone.info = event.info; }
                    break;
            }
        }

        return false;
    }
}
unittest
{
    writeln("ChunkyZoneGenerator unittest");
    scope(success) { writeln("ChunkyZoneGenerator unittest SUCCESS"); }
    scope(failure) { writeln("ChunkyZoneGenerator unittest FAILURE"); }


    const frameCount = 16;

    import std.typecons;
    auto profiler = scoped!Profiler(new ubyte[Profiler.maxEventBytes + 2048]);
    auto chunkyEvents = ChunkyEventList(new ChunkyEventList.Chunk[frameCount + 1]);
    auto chunkyZones = ChunkyZoneGenerator(chunkyEvents.generator);

    size_t lastChunkEnd = 0;
    profiler.checkpointEvent();
    // std.typecons.scoped! stores the Profiler on the stack.
    // Simulate 16 'frames'
    foreach(frame; 0 .. frameCount)
    {
        Zone topLevel = Zone(profiler, "frame");

        // Simulate frame overhead. Replace this with your frame code.
        {
            Zone nested1 = Zone(profiler, "frameStart");
            foreach(i; 0 .. 1000) { continue; }
        }
        {
            Zone nested2 = Zone(profiler, "frameCore");
            foreach(i; 0 .. 10000) { continue; }
        }

        if(!chunkyEvents.addChunk(profiler.profileData[lastChunkEnd .. $].idup))
        {
            assert(false);
        }

        chunkyZones.GeneratedZoneData zone;
        // "frame" zone from the previous frame (in current frame it's still in progress)
        if(frame > 0 && !chunkyZones.generate(zone)) { assert(false); }
        assert(frame == 0 || zone.info == "frame");
        // "frameStart" from current frame
        if(!chunkyZones.generate(zone)) { assert(false); }

        assert(zone.info == "frameStart" &&
               zone.id == frame * 3 + 2 &&
               zone.parentID == frame * 3 + 1
               && zone.nestLevel == 2);
        // "frameCore" from current frame
        if(!chunkyZones.generate(zone)) { assert(false); }
        assert(zone.info == "frameCore" &&
               zone.id == frame * 3 + 3 &&
               zone.parentID == frame * 3 + 1
               && zone.nestLevel == 2);

        lastChunkEnd = profiler.profileData.length;
        profiler.checkpointEvent();
    }

    // Chunk for the last checkpoint/zone end.
    if(!chunkyEvents.addChunk(profiler.profileData[lastChunkEnd .. $].idup))
    {
        assert(false);
    }
}
