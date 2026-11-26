#!/bin/bash
# Offline unit tests for image-builder/builder/j475c_display_dtb.py.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
check=$here/../../image-builder/builder/j475c_display_dtb.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# dtc 1.7 (Ubuntu 24.04) prints a string list as one string with \0.
# dtc 1.8 (the image build) prints separate quotes. The checker reads the
# 1.8 form. This stand-in only rewrites the 1.7 spelling.
mkdir -p "$work/bin"
cat >"$work/bin/dtc" <<'EOF'
#!/bin/bash
real=/usr/bin/dtc
fmt=""
prev=""
for a in "$@"; do
  if [[ $prev == -O ]]; then fmt=$a; fi
  prev=$a
done
if [[ $fmt == dts ]]; then
  "$real" "$@" | python3 -c '
import re, sys
text = sys.stdin.read()
def split_nul(m):
    inner = m.group(1)
    if "\\0" not in inner:
        return m.group(0)
    return ", ".join(f"\"{p}\"" for p in inner.split("\\0"))
sys.stdout.write(re.sub(r"\"((?:[^\"\\]|\\.)*)\"", split_nul, text))
'
else
  exec "$real" "$@"
fi
EOF
chmod +x "$work/bin/dtc"
export PATH="$work/bin:$PATH"

cat >"$work/base.dts" <<'DTS'
/dts-v1/;

/ {
	aliases {
		dcpext0 = "/soc/dcp@289c00000";
		dcpext1 = "/soc/dcp@315c00000";
		dcpext2 = "/soc/dcp@48dc00000";
		dcpext3 = "/soc/dcp@50dc00000";
	};

	clk_dispext2: clock-dispext2 {
		compatible = "fixed-clock";
		#clock-cells = <0>;
		clock-frequency = <0>;
		clock-output-names = "clk_dispext2";
	};

	clk_dispext3: clock-dispext3 {
		compatible = "fixed-clock";
		#clock-cells = <0>;
		clock-frequency = <0>;
		clock-output-names = "clk_dispext3";
	};

	soc {
		#address-cells = <2>;
		#size-cells = <2>;

		dispext0_dart: iommu@289304000 { reg = <0x02 0x89304000 0x00 0x4000>; status = "okay"; };
		dispext1_dart: iommu@315304000 { reg = <0x03 0x15304000 0x00 0x4000>; status = "okay"; };
		m2_dart_dispext2_0: iommu@48d304000 { reg = <0x04 0x8d304000 0x00 0x4000>; apple,dma-range = <0x100 0 0x10 0>; status = "okay"; };
		m2_dart_dcpext2: iommu@48d30c000 { reg = <0x04 0x8d30c000 0x00 0x4000>; apple,dma-range = <0x100 0 0x10 0>; status = "okay"; };
		m2_dart_dispext3_0: iommu@50d304000 { reg = <0x05 0x0d304000 0x00 0x4000>; apple,dma-range = <0x100 0 0x10 0>; status = "okay"; };
		m2_dart_dcpext3: iommu@50d30c000 { reg = <0x05 0x0d30c000 0x00 0x4000>; apple,dma-range = <0x100 0 0x10 0>; status = "okay"; };

		m2_dcpext2_mbox: mailbox@48dc08000 { reg = <0x04 0x8dc08000 0x00 0x4000>; power-domains = <1>; resets = <1>; status = "okay"; };
		m2_dcpext3_mbox: mailbox@50dc08000 { reg = <0x05 0x0dc08000 0x00 0x4000>; power-domains = <1>; resets = <1>; status = "okay"; };

		display-subsystem {
			compatible = "apple,display-subsystem";
			iommus = <&dispext0_dart 0 0x100 0 0x10 0>,
				 <&dispext1_dart 0 0x100 0 0x10 0>,
				 <&m2_dart_dispext2_0 0>,
				 <&m2_dart_dispext3_0 0>;
		};

		dcp@289c00000 { reg = <0x02 0x89c00000 0x00 0x4000>; status = "disabled"; };

		dcp@315c00000 {
			reg = <0x03 0x15c00000 0x00 0x4000>;
			status = "disabled";
			typec-routes {
				#address-cells = <1>;
				#size-cells = <0>;
				route@0 { reg = <0>; mode-switch; port { dcpext1_typec0: endpoint { remote-endpoint = <&typec0_dcp>; }; }; };
				route@1 { reg = <1>; mode-switch; port { dcpext1_typec1: endpoint { remote-endpoint = <&typec1_dcp>; }; }; };
				route@2 { reg = <2>; mode-switch; port { dcpext1_typec2: endpoint { remote-endpoint = <&typec2_dcp>; }; }; };
				route@3 { reg = <3>; mode-switch; port { dcpext1_typec3: endpoint { remote-endpoint = <&typec3_dcp>; }; }; };
			};
		};

		dcp@48dc00000 {
			reg = <0x04 0x8dc00000 0x00 0x4000>;
			status = "disabled";
			apple,connector-type = "USB-C";
			apple,dcp-index = <3>;
			apple,typec-mux-indices = <4 4 4 4>;
			apple,typec-dptx-phys = <0 1 2 3>;
			phy-names = "typec0", "typec1", "typec2", "typec3";
			mux-control-names = "typec0", "typec1", "typec2", "typec3";
			clocks = <&clk_dispext2>;
			apple,bw-scratch = <1>;
			apple,iomfb-surfaces = <1 1 0 1>;
			resets = <1>;
			mboxes = <&m2_dcpext2_mbox>;
			iommus = <&m2_dart_dcpext2 5>;
			typec-routes {
				#address-cells = <1>;
				#size-cells = <0>;
				route@0 { reg = <0>; mode-switch; port { dcpext2_typec0: endpoint { remote-endpoint = <&typec0_dcpext2>; }; }; };
				route@1 { reg = <1>; mode-switch; port { dcpext2_typec1: endpoint { remote-endpoint = <&typec1_dcpext2>; }; }; };
				route@2 { reg = <2>; mode-switch; port { dcpext2_typec2: endpoint { remote-endpoint = <&typec2_dcpext2>; }; }; };
				route@3 { reg = <3>; mode-switch; port { dcpext2_typec3: endpoint { remote-endpoint = <&typec3_dcpext2>; }; }; };
			};
		};

		dcp@50dc00000 {
			reg = <0x05 0x0dc00000 0x00 0x4000>;
			status = "disabled";
			apple,connector-type = "USB-C";
			apple,dcp-index = <4>;
			apple,typec-mux-indices = <6 6 6 6>;
			apple,typec-dptx-phys = <0 1 2 3>;
			phy-names = "typec0", "typec1", "typec2", "typec3";
			mux-control-names = "typec0", "typec1", "typec2", "typec3";
			clocks = <&clk_dispext3>;
			apple,bw-scratch = <1>;
			apple,iomfb-surfaces = <1 1 0 1>;
			resets = <1>;
			mboxes = <&m2_dcpext3_mbox>;
			iommus = <&m2_dart_dcpext3 5>;
			typec-routes {
				#address-cells = <1>;
				#size-cells = <0>;
				route@0 { reg = <0>; mode-switch; port { dcpext3_typec0: endpoint { remote-endpoint = <&typec0_dcpext3>; }; }; };
				route@1 { reg = <1>; mode-switch; port { dcpext3_typec1: endpoint { remote-endpoint = <&typec1_dcpext3>; }; }; };
				route@2 { reg = <2>; mode-switch; port { dcpext3_typec2: endpoint { remote-endpoint = <&typec2_dcpext3>; }; }; };
				route@3 { reg = <3>; mode-switch; port { dcpext3_typec3: endpoint { remote-endpoint = <&typec3_dcpext3>; }; }; };
			};
		};

		i2c {
			#address-cells = <1>;
			#size-cells = <0>;
			usb-pd@38 { reg = <0x38>; connector { compatible = "usb-c-connector"; ports { #address-cells = <1>; #size-cells = <0>; port@3 { #address-cells = <1>; #size-cells = <0>; reg = <3>; typec0_dcp: endpoint@0 { reg = <0>; remote-endpoint = <&dcpext1_typec0>; }; typec0_dcpext2: endpoint@2 { reg = <2>; remote-endpoint = <&dcpext2_typec0>; }; typec0_dcpext3: endpoint@3 { reg = <3>; remote-endpoint = <&dcpext3_typec0>; }; }; }; }; };
			usb-pd@3f { reg = <0x3f>; connector { compatible = "usb-c-connector"; ports { #address-cells = <1>; #size-cells = <0>; port@3 { #address-cells = <1>; #size-cells = <0>; reg = <3>; typec1_dcp: endpoint@0 { reg = <0>; remote-endpoint = <&dcpext1_typec1>; }; typec1_dcpext2: endpoint@2 { reg = <2>; remote-endpoint = <&dcpext2_typec1>; }; typec1_dcpext3: endpoint@3 { reg = <3>; remote-endpoint = <&dcpext3_typec1>; }; }; }; }; };
			usb-pd@3b { reg = <0x3b>; connector { compatible = "usb-c-connector"; ports { #address-cells = <1>; #size-cells = <0>; port@3 { #address-cells = <1>; #size-cells = <0>; reg = <3>; typec2_dcp: endpoint@0 { reg = <0>; remote-endpoint = <&dcpext1_typec2>; }; typec2_dcpext2: endpoint@2 { reg = <2>; remote-endpoint = <&dcpext2_typec2>; }; typec2_dcpext3: endpoint@3 { reg = <3>; remote-endpoint = <&dcpext3_typec2>; }; }; }; }; };
			usb-pd@3c { reg = <0x3c>; connector { compatible = "usb-c-connector"; ports { #address-cells = <1>; #size-cells = <0>; port@3 { #address-cells = <1>; #size-cells = <0>; reg = <3>; typec3_dcp: endpoint@0 { reg = <0>; remote-endpoint = <&dcpext1_typec3>; }; typec3_dcpext2: endpoint@2 { reg = <2>; remote-endpoint = <&dcpext2_typec3>; }; typec3_dcpext3: endpoint@3 { reg = <3>; remote-endpoint = <&dcpext3_typec3>; }; }; }; }; };
		};
	};
};
DTS

compile_check() {
  local name=$1
  dtc -q -I dts -O dtb -o "$work/$name.dtb" "$work/$name.dts"
}

compile_check base
python3 "$check" "$work/base.dtb" >/dev/null
echo "ok - valid j475c multi-display DTB passes"

# 1. dcpext2 must remain disabled in the raw DTB (aura gates enabling on firmware).
sed '0,/status = "disabled";/! { /dcp@48dc00000/,/};/ s/status = "disabled";/status = "okay";/ }' "$work/base.dts" >"$work/okay.dts"
compile_check okay
! python3 "$check" "$work/okay.dtb" >/dev/null 2>&1 || { echo "accepted status=okay dcpext2" >&2; exit 1; }
echo "ok - raw status=okay on dcpext2 is rejected"

# 2. Missing dcpext3 alias is rejected.
grep -v 'dcpext3 = ' "$work/base.dts" >"$work/noalias.dts"
compile_check noalias
! python3 "$check" "$work/noalias.dtb" >/dev/null 2>&1 || { echo "accepted missing dcpext3 alias" >&2; exit 1; }
echo "ok - missing dcpext3 alias is rejected"

# 3. Missing apple,dma-range on a DART is rejected.
sed 's/apple,dma-range = <0x100 0 0x10 0>; //' "$work/base.dts" >"$work/nodma.dts"
compile_check nodma
! python3 "$check" "$work/nodma.dtb" >/dev/null 2>&1 || { echo "accepted DART without apple,dma-range" >&2; exit 1; }
echo "ok - missing apple,dma-range on DART is rejected"

# 4. Missing route@3 on dcpext2/3 (only 3 ports wired) is rejected.
sed -E \
  's/typec3_dcpext2: endpoint@2 \{[^}]*\}; //; s/typec3_dcpext3: endpoint@3 \{[^}]*\}; //; /dcpext2_typec3|dcpext3_typec3/d' \
  "$work/base.dts" >"$work/threeports.dts"
compile_check threeports
! python3 "$check" "$work/threeports.dtb" >/dev/null 2>&1 || { echo "accepted 3-port wiring" >&2; exit 1; }
echo "ok - missing 4th rear USB-C route is rejected"

# 5. Swapped route index on one port@3 is rejected.
sed -e 's/<&dcpext2_typec0>/<\&dcpext2_typec1_tmp>/' \
    -e 's/<&dcpext2_typec1>/<\&dcpext2_typec0>/' \
    -e 's/<&dcpext2_typec1_tmp>/<\&dcpext2_typec1>/' \
    -e 's/<&typec0_dcpext2>/<\&typec1_dcpext2_tmp>/' \
    -e 's/<&typec1_dcpext2>/<\&typec0_dcpext2>/' \
    -e 's/<&typec1_dcpext2_tmp>/<\&typec1_dcpext2>/' \
    "$work/base.dts" >"$work/swapped.dts"
compile_check swapped
! python3 "$check" "$work/swapped.dtb" >/dev/null 2>&1 || { echo "accepted swapped route index" >&2; exit 1; }
echo "ok - swapped typec route index across ports is rejected"

echo "PASS j475c-display-dtb"
