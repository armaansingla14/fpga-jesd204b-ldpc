# run_sweep.tcl - run every generated configuration serially in one Vivado
# session (each build in a fresh in-memory design).
#
#   python scripts/gen_configs.py
#   vivado -mode batch -source vivado/run_sweep.tcl
#
# NOT RUN HERE (Vivado unavailable). For parallel builds use run_sweep.sh.
set root [file normalize [file join [file dirname [info script]] ..]]
set list [file join $root build configs sweep.txt]
set fh [open $list r]
set names [split [string trim [read $fh]] "\n"]
close $fh

set failed {}
foreach n $names {
  puts "=== $n ==="
  set ::argv [list [file join $root build configs $n.tcl]]
  if {[catch {source [file join $root vivado build.tcl]} err]} {
    puts "build $n failed: $err"
    lappend failed $n
  }
  close_project -quiet
}
puts "done: [expr {[llength $names] - [llength $failed]}] / [llength $names] succeeded"
if {[llength $failed]} { puts "failed: $failed" }
