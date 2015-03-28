//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Range that accumulates (merges) matching zones from one or more zone ranges.
module tharsis.prof.accumulatedzonerange;

import std.range;
import std.traits;

import tharsis.prof.ranges;
import tharsis.prof.profiler;
import tharsis.prof.compat;

/** Data accumulated from multiple matching zones, generated by $(D
 *  accumulatedZoneRange()).
 *
 * Extends $(D ZoneData) (derived using alias this) with a value returned by the $(D
 * accumulate) function parameter of $(D accumulatedZoneRange()).
 *
 * Durations and start times of accumulated zones are summed into $(D zoneData.duration)
 * and $(D zoneData.startTime). $(D id), $(D parentID) and $(D nestLevel) are updated so
 * the elements of $(D accumulatedZoneRange) can still form trees just like elements of
 * the $(D ZoneRange) that was accumulated.
 */
struct AccumulatedZoneData(alias accumulate)
{
    /// The 'base' ZoneData; startTime and duration are sums of accumulated ZoneData values.
    ZoneData zoneData;
    alias zoneData this;

    /// The value accumulated by the accumulate function.
    ReturnType!accumulate accumulated;
}


/// Default match function for accumulatedZoneRange(). Compares ZoneData infos for equality.
@nogc bool defaultMatch(const(char)[] info1, const(char)[] info2) @safe pure nothrow
{
    return info1 == info2;
}

/** Returns a range that accumulates (merges) matching zones from one or more zone ranges.
 *
 * On each nesting level from top to bottom, finds zones that $(B match) based on given
 * match function and merges them into one zone, $(B accumulating) data from merged zone
 * using the accumulate function. Merged zones contain summed durations and start times.
 * The default match function compares info strings of two zones for equality.
 *
 *
 * Can be used e.g. to get a 'total' of all recorded frames. If each frame has one
 * top-level zone with matching info strings, the top-level zones are merged, then
 * matching children of these zones, and so on. The result is a zone range representing
 * a single tree. The accumulate function can be used, for example, to calculate max
 * duration of matching zones, getting a 'worst case frame scenario', to calculate the
 * number of times each zone was entered, or even multiple things at the same time.
 *
 * Params:
 *
 * accumulate = A function alias that takes a pointer to the value accumulated so far, and
 *              the next ZoneData to accumulate. It returns the resulting accumulated
 *              value. The first parameter will be null on the first call.
 *
 *              Must be $(D pure nothrow @nogc).
 *
 * match      = A function alias that takes two const(char) arrays and returns a bool.
 *              If true is returned, two zones with whose info strings were passed to
 *              match() are considered the same zone and will be merged and accumulated.
 *
 *              Must be $(D pure nothrow @nogc).
 *
 *              An example use-case for a custom match() function is to accumulate related
 *              zones with slightly different names (e.g. numbered draw batches), or
 *              conversely, to prevent merging zones with identical names (e.g. to see
 *              each individual draw as a separate zone).
 *
 * storage    = Array to use for temporary storage during accumulation $(B as well as)
 *              storage in the returned range. Must be long enough to hold zones from all
 *              passed zone ranges, i.e. the sum of their walkLengths. To determine this
 *              length, use $(D import std.range; zoneRange.walkLength;).
 * zones      = One or more zone ranges to accumulate.
 *
 * Returns: A ForwardRange of AccumulatedZoneData. Each element contails ZoneData plus the
 *          return value of the accumulate function.
 *
 * Note: The current implementation is likely to be slow for large inputs. It's probably
 *       too slow for real-time usage except if the inputs are very small.
 *
 * Example of an $(D accumulate) function:
 * --------------------
 * // Increments the accumulated value when called. Useful to determine the
 * // number of times a Zone was entered.
 * size_t accum(size_t* aPtr, ref const ZoneData z) pure nothrow @nogc
 * {
 *     return aPtr is null ? 1 : *aPtr + 1;
 * }
 * --------------------
 */
@nogc auto accumulatedZoneRange(alias accumulate, alias match = defaultMatch, ZRange)
                         (AccumulatedZoneData!accumulate[] storage, ZRange[] zones...)
    @trusted pure nothrow
{
    static assert(isForwardRange!ZRange && is(Unqual!(ElementType!ZRange) == ZoneData),
                  "ZRange parameter of accumulatedZoneRange must be a forward range of "
                  "ZoneData, e.g. ZoneRange");
    debug
    {
        size_t zoneCount;
        foreach(ref zoneRange; zones) { zoneCount += zoneRange.save.walkLength; }

        assert(storage.length >= zoneCount,
               "storage param of accumulatedZoneRange must be long enough to hold zones "
               "from all passed zone ranges");
    }
    alias AccumulatedZone = AccumulatedZoneData!accumulate;

    // Range returned by this function.
    // Just a restricted array at the moment, but we can change it if we need to.
    struct Range
    {
    private:
        // Array storing the accumulated results. Slice of $(D storage) passed to
        // accumulatedZoneRange
        const(AccumulatedZone)[] array;

        static assert(isForwardRange!Range, "accumulated zone range must be a forward range");
        static assert(is(Unqual!(ElementType!Range) == AccumulatedZone),
                      "accumulated zone range must be a range of AccumulatedZoneData");

    public:
        @nogc @safe pure nothrow:
        // ForwardRange primitives.
        AccumulatedZone front() const { return array.front;  }
        void popFront()               { array.popFront;      }
        bool empty()            const { return array.empty;  }
        @property Range save()  const { return Range(array); }
        // Number of zones in the range.
        size_t length()         const { return array.length; }
    }

    // Copy all zones into storage.
    size_t i = 0;
    foreach(ref zoneRange; zones) foreach(zone; zoneRange.save)
    {
        storage[i++] = AccumulatedZone(zone, accumulate(null, zone));
    }
    storage = storage[0 .. i];

    // Complexity of this is O(log(N) * N^2 + 2N^2) == O(log(N) * N^2).
    // TODO: We could probably speed this up greatly by sorting storage by level, or even
    //       by level first and parent ID second. That would make finding matching nodes
    //       much faster. 2014-08-31

    // Start with merging topmost zones with no parents, then merge their children, etc.
    // All zones in a single level that match are accumulated into one element. parentID
    // of the children of merged zones are updated to point to the resulting zone.
    for(size_t level = 1; ; ++level)
    {
        // We're not done as long as there's at least 1 elem at this nesting level.
        bool notDone = false;
        for(size_t e1Idx; e1Idx < storage.length; ++e1Idx)
        {
            auto e1 = &storage[e1Idx];
            if(e1.nestLevel != level) { continue; }

            notDone = true;

            // Any elems until e1Idx that need to be merged are already merged, so start
            // looking at e2Idx.
            for(size_t e2Idx = e1Idx + 1; e2Idx < storage.length; ++e2Idx)
            {
                auto e2 = &storage[e2Idx];
                if(e1.nestLevel != level) { continue; }

                // Skip if the zones don't match.
                if(e1.parentID != e2.parentID || !match(e1.info, e2.info)) { continue; }

                // Below code runs at most once per zone (a zone can be removed at most once).

                e1.accumulated  = accumulate(&(e1.accumulated), e2.zoneData);
                e1.duration    += e2.duration;
                e1.startTime   += e2.startTime;

                const idToRemove = e2.id;
                const idToReplaceWith = e1.id;

                // Same as `storage = storage.remove(e2Idx);` but @nogc nothrow.
                foreach(offset, ref moveInto; storage[e2Idx .. $ - 1])
                {
                    moveInto = storage[e2Idx + offset + 1];
                }
                storage.popBack();
                // This removes the element at e2Idx (which is greater than e1Idx), so we
                // must go 1 index back, Elements at after e2Idx may also be removed, but
                // that won't break our loop.
                --e2Idx;
                foreach(ref elem; storage) if(elem.parentID == idToRemove)
                {
                    elem.parentID = idToReplaceWith;
                }
            }
        }

        if(!notDone) { break; }
    }

    // Elements that weren't merged were removed from storage in preceding loops, so
    // storage is likely a lot smaller at this point.
    return Range(storage);
}
///
unittest
{
    // Count the number of times each zone was entered.

    import tharsis.prof;

    auto storage  = new ubyte[Profiler.maxEventBytes + 128];
    auto profiler = new Profiler(storage);

    foreach(i; 0 .. 3)
    {
        import std.datetime;
        auto startTime = Clock.currStdTime();
        // Wait long enough so the time gap is represented by >2 bytes.
        while(Clock.currStdTime() - startTime <= 65536) { continue; }
        auto zone1 = Zone(profiler, "zone1");
        {
            auto zone11 = Zone(profiler, "zone11");
        }
        startTime = Clock.currStdTime();
        // Wait long enough so the time gap is represented by >1 bytes.
        while(Clock.currStdTime() - startTime <= 255) { continue; }
        {
            auto zone12 = Zone(profiler, "zone12");
        }
    }


    // Count the number of instances of each zone.
    @nogc size_t accum(size_t* aPtr, ref const ZoneData z) pure nothrow
    {
        return aPtr is null ? 1 : *aPtr + 1;
    }

    auto zones        = profiler.profileData.zoneRange;
    auto accumStorage = new AccumulatedZoneData!accum[zones.walkLength];
    auto accumulated  = accumulatedZoneRange!accum(accumStorage, zones.save);

    assert(accumulated.walkLength == 3);

    import std.stdio;
    foreach(zone; accumulated)
    {
        writeln(zone);
    }
}
///
unittest
{
    // Accumulate minimum, maximum, average duration and more simultaneously.

    // This example also uses C malloc/free, std.typecons.scoped and std.container.Array
    // to show how to do this without using the GC.

    import tharsis.prof;
    import std.algorithm:min,max;

    const storageLength = Profiler.maxEventBytes + 2048;

    import core.stdc.stdlib;
    // A simple typed-slice malloc wrapper function would avoid the ugly cast/slicing.
    ubyte[] storage  = (cast(ubyte*)malloc(storageLength))[0 .. storageLength];
    scope(exit) { free(storage.ptr); }

    import std.typecons;
    // std.typecons.scoped! stores the Profiler on the stack.
    auto profiler = scoped!Profiler(storage);

    // Simulate 16 'frames'
    foreach(frame; 0 .. 16)
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
    }

    // Accumulate data into this struct.
    struct ZoneStats
    {
        ulong minDuration;
        ulong maxDuration;
        // Needed to calculate average duration.
        size_t instanceCount;

        // We also need the total duration to calculate average, but that is accumulated
        // by default in AccumulatedZoneData.
    }

    // Gets min, max, total duration as well as the number of times the zone was entered.
    @nogc ZoneStats accum(ZoneStats* aPtr, ref const ZoneData z) pure nothrow
    {
        if(aPtr is null) { return ZoneStats(z.duration, z.duration, 1); }

        return ZoneStats(min(aPtr.minDuration, z.duration),
                        max(aPtr.maxDuration, z.duration),
                        aPtr.instanceCount + 1);
    }

    auto zones      = profiler.profileData.zoneRange;
    // Allocate storage to accumulate in with malloc.
    const zoneCount = zones.walkLength;
    alias Data = AccumulatedZoneData!accum;
    auto accumStorage = (cast(Data*)malloc(zoneCount * Data.sizeof))[0 .. zoneCount];
    scope(exit) { free(accumStorage.ptr); }

    auto accumulated = accumulatedZoneRange!accum(accumStorage, zones.save);

    // Write out the results.
    foreach(zone; accumulated) with(zone.accumulated)
    {
        import std.stdio;
        writefln("id: %s, min: %s, max: %s, avg: %s, total: %s, count: %s",
                 zone.id, minDuration, maxDuration,
                 zone.duration / cast(double)instanceCount, zone.duration, instanceCount);
    }
}
///
unittest
{
    // Get the average duration of a top-level zone. This is a good way to determine
    // average frame duration as the top-level zone often encapsulates a frame.

    // This example also uses C malloc/free, std.typecons.scoped and std.container.Array
    // to show how to do this without using the GC.

    import tharsis.prof;

    const storageLength = Profiler.maxEventBytes + 2048;

    import core.stdc.stdlib;
    // A simple typed-slice malloc wrapper function would avoid the ugly cast/slicing.
    ubyte[] storage  = (cast(ubyte*)malloc(storageLength))[0 .. storageLength];
    scope(exit) { free(storage.ptr); }

    import std.typecons;
    // std.typecons.scoped! stores the Profiler on the stack.
    auto profiler = scoped!Profiler(storage);

    // Simulate 16 'frames'
    foreach(frame; 0 .. 16)
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
    }

    // Count the number of instances of each zone.
    @nogc size_t accum(size_t* aPtr, ref const ZoneData z) pure nothrow
    {
        return aPtr is null ? 1 : *aPtr + 1;
    }

    import std.algorithm;
    // Top-level zones are level 1.
    //
    // Filtering zones before accumulating allows us to decrease memory space needed for
    // accumulation, as well as speed up the accumulation, which is relatively expensive.
    auto zones = profiler.profileData.zoneRange.filter!(z => z.nestLevel == 1);
    // Allocate storage to accumulate in with malloc.
    const zoneCount = zones.walkLength;
    alias Data = AccumulatedZoneData!accum;
    auto accumStorage = (cast(Data*)malloc(zoneCount * Data.sizeof))[0 .. zoneCount];
    scope(exit) { free(accumStorage.ptr); }

    auto accumulated = accumulatedZoneRange!accum(accumStorage, zones.save);

    // If there is just one top-level zone, and it always has the same info ("frame" in
    // this case), accumulatedZoneRange with the default match function will have exactly
    // 1 element; with the accumulated result for all instances of the zone. Also here,
    // we use $(D duration), which is accumulated by default.
    import std.stdio;
    writeln(accumulated.front.duration / cast(real)accumulated.front.accumulated);
}
