#!/usr/bin/env python
import sys

# band hs1 p36.32 p36.32 2200000 5100000 gpos25
# band hs1 p36.31 p36.31 5100000 6900000 gneg
# band hs1 p36.23 p36.23 6900000 8800000 gpos25
COLS = (
    "chrom",
    "chromStart",
    "chromEnd",
    "name",
    "score",
    "strand",
    "thickStart",
    "thickEnd",
    "itemRgb",
)

colormap = {}
# Process optional cytogenetic bands
#     band
#     ID
#     parentChr
#     parentChr
#     START
#     END COLOR
with open(sys.argv[1], "r") as handle:
    for line in handle:
        if line.startswith("#"):
            continue

        lineData = dict(zip(COLS, line.split()))
        color = lineData.get("itemRgb", "gpos50")

        if color not in colormap:
            # Color MUST be an RGB triplet
            if color.count(",") != 2:
                continue
            tmp = color.replace(",", "")
            # Try interpreting it, without `,`s as an integer. If it fails this
            # test there are non-numerical values and they might try and send
            # us an `eval()` or a colour name. We do not currently support
            # colour names just in case.
            try:
                int(tmp)
            except ValueError:
                # Does not look like an int
                continue

            colormap[color] = "gx-karyotype-%s" % len(colormap.keys())

            sys.stderr.write(
                "{colorName} = {color}\n".format(colorName=colormap[color], color=color)
            )

        sys.stdout.write(
            "band {chrom} {name} {name} {chromStart} {chromEnd} {color}\n".format(
                # Can access name because requiring >bed3
                name=lineData["name"],
                chrom=lineData["chrom"],
                chromStart=lineData["chromStart"],
                chromEnd=lineData["chromEnd"],
                # 255,0,0 is a valid colour specifier
                color=colormap[color],
            )
        )


# chrom - The name of the chromosome (e.g. chr3, chrY, chr2_random) or scaffold (e.g. scaffold10671).
# chromStart - The starting position of the feature in the chromosome or scaffold. The first base in a chromosome is numbered 0.
# chromEnd - The ending position of the feature in the chromosome or scaffold. The chromEnd base is not included in the display of the feature. For example, the first 100 bases of a chromosome are defined as chromStart=0, chromEnd=100, and span the bases numbered 0-99.
# name - Defines the name of the BED line. This label is displayed to the left of the BED line in the Genome Browser window when the track is open to full display mode or directly to the left of the item in pack mode.
# score - A score between 0 and 1000. If the track line useScore attribute is set to 1 for this annotation data set, the score value will determine the level of gray in which this feature is displayed (higher numbers = darker gray). This table shows the Genome Browser's translation of BED score values into shades of gray:
# strand - Defines the strand - either '+' or '-'.
# thickStart - The starting position at which the feature is drawn thickly (for example, the start codon in gene displays). When there is no thick part, thickStart and thickEnd are usually set to the chromStart position.
# thickEnd - The ending position at which the feature is drawn thickly (for example, the stop codon in gene displays).
# itemRgb - An RGB value of the form R,G,B (e.g. 255,0,0). If the track line itemRgb attribute is set to "On", this RBG value will determine the display color of the data contained in this BED line. NOTE: It is recommended that a simple color scheme (eight colors or less) be used with this attribute to avoid overwhelming the color resources of the Genome Browser and your Internet browser.
# blockCount - The number of blocks (exons) in the BED line.
# blockSizes - A comma-separated list of the block sizes. The number of items in this list should correspond to blockCount.
# blockStarts - A comma-separated list of block starts. All of the blockStart positions should be calculated relative to chromStart. The number of items in this list should correspond to blockCount.
