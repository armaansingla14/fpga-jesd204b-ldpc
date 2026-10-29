# build.tcl - Vivado non-project-mode build of fpga_top for one configuration.
#
#   vivado -mode batch -source vivado/build.tcl -tclargs build/configs/L4_D2_C246_S1.tcl
#
# NOT RUN HERE: Vivado is not available in this environment. No timing,
# utilisation or power results are claimed for these builds.
#
# Outputs (vivado_runs/<name>/): post-synth/route checkpoints, utilisation,
# timing summary, power report and a one-line summary.csv.

if {[llength $argv] < 1} { error "usage: build.tcl <config.tcl>" }
source [lindex $argv 0]

set root   [file normalize [file join [file dirname [info script]] ..]]
set outdir [file join $root vivado_runs $CFG(name)]
file mkdir $outdir
set_param general.maxThreads 4

# ------------------------------------------------------------------ sources
set rtl {
  rtl/jesd/jesd_pkg.sv rtl/jesd/enc_8b10b.sv rtl/jesd/dec_8b10b.sv
  rtl/jesd/comma_align.sv rtl/jesd/jesd_tx.sv rtl/jesd/jesd_rx.sv
  rtl/ldpc/ldpc_encoder.sv rtl/ldpc/ldpc_decoder.sv rtl/ldpc/ldpc_dec_array.sv
  rtl/top/fpga_top.sv
}
foreach f $rtl { read_verilog -sv [file join $root $f] }
set_property include_dirs [list [file join $root rtl ldpc]] [current_fileset]

# Constraints are generated per configuration (clock period differs).
set xdc [file join $outdir clocks.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name dev_clk -period $CFG(period) \[get_ports clk\]"
puts $fh "set_false_path -from \[get_ports rst_n\]"
puts $fh "set_input_delay  -clock dev_clk 0.5 \[get_ports -filter {DIRECTION == IN && NAME != clk}\]"
puts $fh "set_output_delay -clock dev_clk 0.5 \[all_outputs\]"
close $fh
read_xdc $xdc

# ---------------------------------------------------------------- synthesis
# Out-of-context: the wide LLR/codeword buses are not meant to be pinned out.
synth_design -top fpga_top -part $CFG(part) -mode out_of_context \
  -generic L=$CFG(L) -generic NUM_DEC=$CFG(NUM_DEC) -generic SCR=$CFG(SCR) \
  -generic F=$CFG(F) -generic K=$CFG(K) -generic MAX_ITER=$CFG(MAX_ITER)
write_checkpoint -force [file join $outdir post_synth.dcp]
report_utilization -file [file join $outdir util_synth.rpt]

# ------------------------------------------------------------ implementation
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $outdir post_route.dcp]

report_utilization    -file [file join $outdir util_route.rpt]
report_timing_summary -file [file join $outdir timing.rpt] -max_paths 20
report_power          -file [file join $outdir power.rpt]

# --------------------------------------------------------------- summary row
set wns  [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set luts [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
set ffs  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == REGISTER}]]
set pwr  [get_property TOTAL_POWER [lindex [get_power_results] 0]]
set fh [open [file join $outdir summary.csv] w]
puts $fh "name,L,NUM_DEC,SCR,clk_mhz,wns_ns,luts,ffs,total_power_w"
puts $fh "$CFG(name),$CFG(L),$CFG(NUM_DEC),$CFG(SCR),$CFG(clk_mhz),$wns,$luts,$ffs,$pwr"
close $fh
puts "build $CFG(name): WNS=$wns ns LUT=$luts FF=$ffs P=$pwr W"
