import ChargeLightCommands
import Foundation

// Taken first: a claim's ordering stamp is the moment this process started.
let stamp = clock_gettime_nsec_np(CLOCK_REALTIME)
exit(runChargeLight(arguments: Array(CommandLine.arguments.dropFirst()), stamp: stamp))
