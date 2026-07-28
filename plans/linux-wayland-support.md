
# Make App / Window Provider for Linux-Wayland

now 
* NucleantVulkan
* NucleantSkia
* NucleantThorVG 

has linux support

and its time to make linux app / window setup like we done so far 
with macos / ios

only now its should be wayland doing it on linux

fill out the 
* NucleantApplication/Sources/Platform_Linux

soo it has its own setup for linux only..

and like macos/ios we need callback to wayland equal to displaylink..
and forward window size changes / mouse / touch(linux can support multi touch) keyboard etc..

