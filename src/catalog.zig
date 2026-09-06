//! Built-in knowledge SIMBAD lacks: the Caldwell catalogue (not in SIMBAD at
//! all) and the popular nicknames astrophotographers use, many of which
//! SIMBAD does not carry. Plus an optional user names file for personal
//! additions.
//!
//! All designations are compared in `lookup.normalize` form.
//!
//! Port of the Rust `catalog.rs`.

const std = @import("std");
const normalize = @import("lookup.zig").normalize;

pub const Caldwell = struct { n: u32, designations: []const []const u8, name: ?[]const u8 };

/// (Caldwell number, designations (first = the one to look up in SIMBAD),
/// popular name). Source: the published Caldwell list.
pub const CALDWELL = [_]Caldwell{
    .{ .n = 1, .designations = &.{"NGC 188"}, .name = "Polarissima Cluster" },
    .{ .n = 2, .designations = &.{"NGC 40"}, .name = "Bow-Tie Nebula" },
    .{ .n = 3, .designations = &.{"NGC 4236"}, .name = null },
    .{ .n = 4, .designations = &.{"NGC 7023"}, .name = "Iris Nebula" },
    .{ .n = 5, .designations = &.{"IC 342"}, .name = "Hidden Galaxy" },
    .{ .n = 6, .designations = &.{"NGC 6543"}, .name = "Cat's Eye Nebula" },
    .{ .n = 7, .designations = &.{"NGC 2403"}, .name = null },
    .{ .n = 8, .designations = &.{"NGC 559"}, .name = null },
    .{ .n = 9, .designations = &.{"Sh2-155"}, .name = "Cave Nebula" },
    .{ .n = 10, .designations = &.{"NGC 663"}, .name = null },
    .{ .n = 11, .designations = &.{"NGC 7635"}, .name = "Bubble Nebula" },
    .{ .n = 12, .designations = &.{"NGC 6946"}, .name = "Fireworks Galaxy" },
    .{ .n = 13, .designations = &.{"NGC 457"}, .name = "Owl Cluster" },
    .{ .n = 14, .designations = &.{ "NGC 869", "NGC 884" }, .name = "Double Cluster" },
    .{ .n = 15, .designations = &.{"NGC 6826"}, .name = "Blinking Planetary" },
    .{ .n = 16, .designations = &.{"NGC 7243"}, .name = null },
    .{ .n = 17, .designations = &.{"NGC 147"}, .name = null },
    .{ .n = 18, .designations = &.{"NGC 185"}, .name = null },
    .{ .n = 19, .designations = &.{"IC 5146"}, .name = "Cocoon Nebula" },
    .{ .n = 20, .designations = &.{"NGC 7000"}, .name = "North America Nebula" },
    .{ .n = 21, .designations = &.{"NGC 4449"}, .name = null },
    .{ .n = 22, .designations = &.{"NGC 7662"}, .name = "Blue Snowball Nebula" },
    .{ .n = 23, .designations = &.{"NGC 891"}, .name = "Silver Sliver Galaxy" },
    .{ .n = 24, .designations = &.{"NGC 1275"}, .name = "Perseus A" },
    .{ .n = 25, .designations = &.{"NGC 2419"}, .name = "Intergalactic Wanderer" },
    .{ .n = 26, .designations = &.{"NGC 4244"}, .name = "Silver Needle Galaxy" },
    .{ .n = 27, .designations = &.{"NGC 6888"}, .name = "Crescent Nebula" },
    .{ .n = 28, .designations = &.{"NGC 752"}, .name = null },
    .{ .n = 29, .designations = &.{"NGC 5005"}, .name = null },
    .{ .n = 30, .designations = &.{"NGC 7331"}, .name = "Deer Lick Group" },
    .{ .n = 31, .designations = &.{"IC 405"}, .name = "Flaming Star Nebula" },
    .{ .n = 32, .designations = &.{"NGC 4631"}, .name = "Whale Galaxy" },
    .{ .n = 33, .designations = &.{"NGC 6992"}, .name = "Eastern Veil Nebula" },
    .{ .n = 34, .designations = &.{"NGC 6960"}, .name = "Western Veil Nebula" },
    .{ .n = 35, .designations = &.{"NGC 4889"}, .name = null },
    .{ .n = 36, .designations = &.{"NGC 4559"}, .name = null },
    .{ .n = 37, .designations = &.{"NGC 6885"}, .name = null },
    .{ .n = 38, .designations = &.{"NGC 4565"}, .name = "Needle Galaxy" },
    .{ .n = 39, .designations = &.{"NGC 2392"}, .name = "Eskimo Nebula" },
    .{ .n = 40, .designations = &.{"NGC 3626"}, .name = null },
    .{ .n = 41, .designations = &.{"Mel 25"}, .name = "Hyades" },
    .{ .n = 42, .designations = &.{"NGC 7006"}, .name = null },
    .{ .n = 43, .designations = &.{"NGC 7814"}, .name = "Little Sombrero Galaxy" },
    .{ .n = 44, .designations = &.{"NGC 7479"}, .name = "Superman Galaxy" },
    .{ .n = 45, .designations = &.{"NGC 5248"}, .name = null },
    .{ .n = 46, .designations = &.{"NGC 2261"}, .name = "Hubble's Variable Nebula" },
    .{ .n = 47, .designations = &.{"NGC 6934"}, .name = null },
    .{ .n = 48, .designations = &.{"NGC 2775"}, .name = null },
    .{ .n = 49, .designations = &.{"NGC 2237"}, .name = "Rosette Nebula" },
    .{ .n = 50, .designations = &.{"NGC 2244"}, .name = null },
    .{ .n = 51, .designations = &.{"IC 1613"}, .name = null },
    .{ .n = 52, .designations = &.{"NGC 4697"}, .name = null },
    .{ .n = 53, .designations = &.{"NGC 3115"}, .name = "Spindle Galaxy" },
    .{ .n = 54, .designations = &.{"NGC 2506"}, .name = null },
    .{ .n = 55, .designations = &.{"NGC 7009"}, .name = "Saturn Nebula" },
    .{ .n = 56, .designations = &.{"NGC 246"}, .name = "Skull Nebula" },
    .{ .n = 57, .designations = &.{"NGC 6822"}, .name = "Barnard's Galaxy" },
    .{ .n = 58, .designations = &.{"NGC 2360"}, .name = "Caroline's Cluster" },
    .{ .n = 59, .designations = &.{"NGC 3242"}, .name = "Ghost of Jupiter" },
    .{ .n = 60, .designations = &.{"NGC 4038"}, .name = "Antennae Galaxies" },
    .{ .n = 61, .designations = &.{"NGC 4039"}, .name = "Antennae Galaxies" },
    .{ .n = 62, .designations = &.{"NGC 247"}, .name = null },
    .{ .n = 63, .designations = &.{"NGC 7293"}, .name = "Helix Nebula" },
    .{ .n = 64, .designations = &.{"NGC 2362"}, .name = "Tau Canis Majoris Cluster" },
    .{ .n = 65, .designations = &.{"NGC 253"}, .name = "Sculptor Galaxy" },
    .{ .n = 66, .designations = &.{"NGC 5694"}, .name = null },
    .{ .n = 67, .designations = &.{"NGC 1097"}, .name = null },
    .{ .n = 68, .designations = &.{"NGC 6729"}, .name = null },
    .{ .n = 69, .designations = &.{"NGC 6302"}, .name = "Butterfly Nebula" },
    .{ .n = 70, .designations = &.{"NGC 300"}, .name = "Sculptor Pinwheel Galaxy" },
    .{ .n = 71, .designations = &.{"NGC 2477"}, .name = null },
    .{ .n = 72, .designations = &.{"NGC 55"}, .name = "String of Pearls Galaxy" },
    .{ .n = 73, .designations = &.{"NGC 1851"}, .name = null },
    .{ .n = 74, .designations = &.{"NGC 3132"}, .name = "Eight-Burst Nebula" },
    .{ .n = 75, .designations = &.{"NGC 6124"}, .name = null },
    .{ .n = 76, .designations = &.{"NGC 6231"}, .name = null },
    .{ .n = 77, .designations = &.{"NGC 5128"}, .name = "Centaurus A" },
    .{ .n = 78, .designations = &.{"NGC 6541"}, .name = null },
    .{ .n = 79, .designations = &.{"NGC 3201"}, .name = null },
    .{ .n = 80, .designations = &.{"NGC 5139"}, .name = "Omega Centauri" },
    .{ .n = 81, .designations = &.{"NGC 6352"}, .name = null },
    .{ .n = 82, .designations = &.{"NGC 6193"}, .name = null },
    .{ .n = 83, .designations = &.{"NGC 4945"}, .name = null },
    .{ .n = 84, .designations = &.{"NGC 5286"}, .name = null },
    .{ .n = 85, .designations = &.{"IC 2391"}, .name = "Omicron Velorum Cluster" },
    .{ .n = 86, .designations = &.{"NGC 6397"}, .name = null },
    .{ .n = 87, .designations = &.{"NGC 1261"}, .name = null },
    .{ .n = 88, .designations = &.{"NGC 5823"}, .name = null },
    .{ .n = 89, .designations = &.{"NGC 6087"}, .name = "S Normae Cluster" },
    .{ .n = 90, .designations = &.{"NGC 2867"}, .name = null },
    .{ .n = 91, .designations = &.{"NGC 3532"}, .name = "Wishing Well Cluster" },
    .{ .n = 92, .designations = &.{"NGC 3372"}, .name = "Carina Nebula" },
    .{ .n = 93, .designations = &.{"NGC 6752"}, .name = "Great Peacock Globular" },
    .{ .n = 94, .designations = &.{"NGC 4755"}, .name = "Jewel Box Cluster" },
    .{ .n = 95, .designations = &.{"NGC 6025"}, .name = null },
    .{ .n = 96, .designations = &.{"NGC 2516"}, .name = "Southern Beehive Cluster" },
    .{ .n = 97, .designations = &.{"NGC 3766"}, .name = "Pearl Cluster" },
    .{ .n = 98, .designations = &.{"NGC 4609"}, .name = null },
    .{ .n = 99, .designations = &.{"Coalsack"}, .name = "Coalsack Nebula" },
    .{ .n = 100, .designations = &.{"IC 2944"}, .name = "Running Chicken Nebula" },
    .{ .n = 101, .designations = &.{"NGC 6744"}, .name = null },
    .{ .n = 102, .designations = &.{"IC 2602"}, .name = "Southern Pleiades" },
    .{ .n = 103, .designations = &.{"NGC 2070"}, .name = "Tarantula Nebula" },
    .{ .n = 104, .designations = &.{"NGC 362"}, .name = null },
    .{ .n = 105, .designations = &.{"NGC 4833"}, .name = null },
    .{ .n = 106, .designations = &.{"NGC 104"}, .name = "47 Tucanae" },
    .{ .n = 107, .designations = &.{"NGC 6101"}, .name = null },
    .{ .n = 108, .designations = &.{"NGC 4372"}, .name = null },
    .{ .n = 109, .designations = &.{"NGC 3195"}, .name = null },
};

/// Popular names for other frequently imaged objects that SIMBAD either lacks
/// or lists under a less common variant.
pub const POPULAR_NAMES = [_]struct { d: []const u8, name: []const u8 }{
    .{ .d = "M 1", .name = "Crab Nebula" },
    .{ .d = "M 6", .name = "Butterfly Cluster" },
    .{ .d = "M 7", .name = "Ptolemy's Cluster" },
    .{ .d = "M 8", .name = "Lagoon Nebula" },
    .{ .d = "M 11", .name = "Wild Duck Cluster" },
    .{ .d = "M 12", .name = "Gumball Globular" },
    .{ .d = "M 13", .name = "Great Hercules Cluster" },
    .{ .d = "M 15", .name = "Great Pegasus Cluster" },
    .{ .d = "M 16", .name = "Eagle Nebula" },
    .{ .d = "M 17", .name = "Omega Nebula" },
    .{ .d = "M 20", .name = "Trifid Nebula" },
    .{ .d = "M 22", .name = "Great Sagittarius Cluster" },
    .{ .d = "M 24", .name = "Sagittarius Star Cloud" },
    .{ .d = "M 27", .name = "Dumbbell Nebula" },
    .{ .d = "M 29", .name = "Cooling Tower" },
    .{ .d = "M 30", .name = "Jellyfish Cluster" },
    .{ .d = "M 31", .name = "Andromeda Galaxy" },
    .{ .d = "M 33", .name = "Triangulum Galaxy" },
    .{ .d = "M 34", .name = "Spiral Cluster" },
    .{ .d = "M 35", .name = "Shoe-Buckle Cluster" },
    .{ .d = "M 36", .name = "Pinwheel Cluster" },
    .{ .d = "M 38", .name = "Starfish Cluster" },
    .{ .d = "M 40", .name = "Winnecke 4" },
    .{ .d = "M 41", .name = "Little Beehive Cluster" },
    .{ .d = "M 42", .name = "Orion Nebula" },
    .{ .d = "M 43", .name = "De Mairan's Nebula" },
    .{ .d = "M 44", .name = "Beehive Cluster" },
    .{ .d = "M 45", .name = "Pleiades" },
    .{ .d = "M 50", .name = "Heart-Shaped Cluster" },
    .{ .d = "M 51", .name = "Whirlpool Galaxy" },
    .{ .d = "M 52", .name = "Salt and Pepper Cluster" },
    .{ .d = "M 55", .name = "Specter Cluster" },
    .{ .d = "M 57", .name = "Ring Nebula" },
    .{ .d = "M 61", .name = "Swelling Spiral Galaxy" },
    .{ .d = "M 62", .name = "Flickering Globular Cluster" },
    .{ .d = "M 63", .name = "Sunflower Galaxy" },
    .{ .d = "M 64", .name = "Black Eye Galaxy" },
    .{ .d = "M 65", .name = "Leo Triplet" },
    .{ .d = "M 66", .name = "Leo Triplet" },
    .{ .d = "M 67", .name = "Golden Eye Cluster" },
    .{ .d = "M 71", .name = "Angelfish Cluster" },
    .{ .d = "M 74", .name = "Phantom Galaxy" },
    .{ .d = "M 76", .name = "Little Dumbbell Nebula" },
    .{ .d = "M 77", .name = "Cetus A" },
    .{ .d = "M 78", .name = "Casper the Friendly Ghost Nebula" },
    .{ .d = "M 81", .name = "Bode's Galaxy" },
    .{ .d = "M 82", .name = "Cigar Galaxy" },
    .{ .d = "M 83", .name = "Southern Pinwheel Galaxy" },
    .{ .d = "M 87", .name = "Virgo A" },
    .{ .d = "M 93", .name = "Critter Cluster" },
    .{ .d = "M 94", .name = "Croc's Eye Galaxy" },
    .{ .d = "M 97", .name = "Owl Nebula" },
    .{ .d = "M 99", .name = "Coma Pinwheel Galaxy" },
    .{ .d = "M 101", .name = "Pinwheel Galaxy" },
    .{ .d = "M 102", .name = "Spindle Galaxy" },
    .{ .d = "M 104", .name = "Sombrero Galaxy" },
    .{ .d = "M 107", .name = "Crucifix Cluster" },
    .{ .d = "M 108", .name = "Surfboard Galaxy" },
    .{ .d = "NGC 281", .name = "Pacman Nebula" },
    .{ .d = "NGC 896", .name = "Fish Head Nebula" },
    .{ .d = "NGC 1333", .name = "Embryo Nebula" },
    .{ .d = "NGC 1360", .name = "Robin's Egg Nebula" },
    .{ .d = "NGC 1435", .name = "Merope Nebula" },
    .{ .d = "NGC 1491", .name = "Fossil Footprint Nebula" },
    .{ .d = "NGC 1499", .name = "California Nebula" },
    .{ .d = "NGC 1514", .name = "Crystal Ball Nebula" },
    .{ .d = "NGC 1535", .name = "Cleopatra's Eye" },
    .{ .d = "NGC 1555", .name = "Hind's Variable Nebula" },
    .{ .d = "NGC 1579", .name = "Northern Trifid Nebula" },
    .{ .d = "NGC 1931", .name = "Fly Nebula" },
    .{ .d = "NGC 1977", .name = "Running Man Nebula" },
    .{ .d = "NGC 2024", .name = "Flame Nebula" },
    .{ .d = "NGC 2170", .name = "Angel Nebula" },
    .{ .d = "NGC 2174", .name = "Monkey Head Nebula" },
    .{ .d = "NGC 2264", .name = "Christmas Tree Cluster" },
    .{ .d = "NGC 2359", .name = "Thor's Helmet" },
    .{ .d = "NGC 2371", .name = "Gemini Nebula" },
    .{ .d = "NGC 2467", .name = "Skull and Crossbones Nebula" },
    .{ .d = "NGC 2736", .name = "Pencil Nebula" },
    .{ .d = "NGC 3324", .name = "Gabriela Mistral Nebula" },
    .{ .d = "NGC 3576", .name = "Statue of Liberty Nebula" },
    .{ .d = "NGC 3918", .name = "Blue Planetary Nebula" },
    .{ .d = "NGC 5189", .name = "Spiral Planetary Nebula" },
    .{ .d = "NGC 6164", .name = "Dragon's Egg Nebula" },
    .{ .d = "NGC 6188", .name = "Rim Nebula" },
    .{ .d = "NGC 6210", .name = "Turtle Nebula" },
    .{ .d = "NGC 6334", .name = "Cat's Paw Nebula" },
    .{ .d = "NGC 6357", .name = "War and Peace Nebula" },
    .{ .d = "NGC 6369", .name = "Little Ghost Nebula" },
    .{ .d = "NGC 6537", .name = "Red Spider Nebula" },
    .{ .d = "NGC 6572", .name = "Blue Racquetball Nebula" },
    .{ .d = "NGC 6751", .name = "Glowing Eye Nebula" },
    .{ .d = "NGC 6818", .name = "Little Gem Nebula" },
    .{ .d = "NGC 6905", .name = "Blue Flash Nebula" },
    .{ .d = "NGC 6979", .name = "Pickering's Triangle" },
    .{ .d = "NGC 6995", .name = "Bat Nebula" },
    .{ .d = "NGC 7008", .name = "Fetus Nebula" },
    .{ .d = "NGC 7027", .name = "Jewel Bug Nebula" },
    .{ .d = "NGC 7380", .name = "Wizard Nebula" },
    .{ .d = "NGC 7822", .name = "Teddy Bear Nebula" },
    .{ .d = "NGC 7538", .name = "Northern Lagoon Nebula" },
    .{ .d = "IC 63", .name = "Ghost of Cassiopeia" },
    .{ .d = "IC 410", .name = "Tadpoles Nebula" },
    .{ .d = "IC 417", .name = "Spider Nebula" },
    .{ .d = "IC 443", .name = "Jellyfish Nebula" },
    .{ .d = "IC 1318", .name = "Sadr Region" },
    .{ .d = "IC 1396", .name = "Elephant's Trunk Nebula" },
    .{ .d = "IC 1795", .name = "Fish Head Nebula" },
    .{ .d = "IC 1805", .name = "Heart Nebula" },
    .{ .d = "IC 1848", .name = "Soul Nebula" },
    .{ .d = "IC 2118", .name = "Witch Head Nebula" },
    .{ .d = "IC 2177", .name = "Seagull Nebula" },
    .{ .d = "IC 4406", .name = "Retina Nebula" },
    .{ .d = "IC 4592", .name = "Blue Horsehead Nebula" },
    .{ .d = "IC 4604", .name = "Rho Ophiuchi Nebula" },
    .{ .d = "IC 4628", .name = "Prawn Nebula" },
    .{ .d = "IC 5070", .name = "Pelican Nebula" },
    .{ .d = "Sh2-82", .name = "Little Cocoon Nebula" },
    .{ .d = "Sh2-101", .name = "Tulip Nebula" },
    .{ .d = "Sh2-106", .name = "Celestial Snow Angel" },
    .{ .d = "Sh2-114", .name = "Flying Dragon Nebula" },
    .{ .d = "Sh2-129", .name = "Flying Bat Nebula" },
    .{ .d = "Sh2-132", .name = "Lion Nebula" },
    .{ .d = "Sh2-142", .name = "Wizard Nebula" },
    .{ .d = "Sh2-157", .name = "Lobster Claw Nebula" },
    .{ .d = "Sh2-158", .name = "Northern Lagoon Nebula" },
    .{ .d = "Sh2-162", .name = "Bubble Nebula" },
    .{ .d = "Sh2-190", .name = "Heart Nebula" },
    .{ .d = "Sh2-199", .name = "Soul Nebula" },
    .{ .d = "Sh2-206", .name = "Fossil Footprint Nebula" },
    .{ .d = "Sh2-220", .name = "California Nebula" },
    .{ .d = "Sh2-229", .name = "Flaming Star Nebula" },
    .{ .d = "Sh2-236", .name = "Tadpoles Nebula" },
    .{ .d = "Sh2-240", .name = "Spaghetti Nebula" },
    .{ .d = "Sh2-248", .name = "Jellyfish Nebula" },
    .{ .d = "Sh2-252", .name = "Monkey Head Nebula" },
    .{ .d = "Sh2-261", .name = "Lower's Nebula" },
    .{ .d = "Sh2-264", .name = "Angelfish Nebula" },
    .{ .d = "Sh2-273", .name = "Cone Nebula" },
    .{ .d = "Sh2-274", .name = "Medusa Nebula" },
    .{ .d = "Sh2-275", .name = "Rosette Nebula" },
    .{ .d = "Sh2-276", .name = "Barnard's Loop" },
    .{ .d = "Sh2-279", .name = "Running Man Nebula" },
    .{ .d = "Sh2-296", .name = "Seagull Nebula" },
    .{ .d = "Sh2-308", .name = "Dolphin Head Nebula" },
    .{ .d = "Barnard 33", .name = "Horsehead Nebula" },
    .{ .d = "Barnard 72", .name = "Snake Nebula" },
    .{ .d = "Barnard 150", .name = "Seahorse Nebula" },
    .{ .d = "LDN 1235", .name = "Dark Shark Nebula" },
    .{ .d = "LDN 1622", .name = "Boogeyman Nebula" },
    .{ .d = "vdB 141", .name = "Ghost Nebula" },
    .{ .d = "NGC 1316", .name = "Fornax A" },
    .{ .d = "NGC 1317", .name = "Fornax B" },
    .{ .d = "NGC 1365", .name = "Great Barred Spiral Galaxy" },
    .{ .d = "NGC 1566", .name = "Spanish Dancer Galaxy" },
    .{ .d = "NGC 2442", .name = "Meathook Galaxy" },
    .{ .d = "NGC 2537", .name = "Bear's Paw Galaxy" },
    .{ .d = "NGC 2683", .name = "UFO Galaxy" },
    .{ .d = "NGC 2841", .name = "Tiger's Eye Galaxy" },
    .{ .d = "NGC 3184", .name = "Little Pinwheel Galaxy" },
    .{ .d = "NGC 3344", .name = "Sliced Onion Galaxy" },
    .{ .d = "NGC 3521", .name = "Bubble Galaxy" },
    .{ .d = "NGC 3628", .name = "Hamburger Galaxy" },
    .{ .d = "NGC 4435", .name = "Eyes Galaxies" },
    .{ .d = "NGC 4438", .name = "Eyes Galaxies" },
    .{ .d = "NGC 4490", .name = "Cocoon Galaxy" },
    .{ .d = "NGC 4535", .name = "Lost Galaxy" },
    .{ .d = "NGC 4567", .name = "Butterfly Galaxies" },
    .{ .d = "NGC 4568", .name = "Siamese Twins" },
    .{ .d = "NGC 4656", .name = "Hockey Stick Galaxy" },
    .{ .d = "NGC 4676", .name = "Mice Galaxies" },
    .{ .d = "NGC 5907", .name = "Splinter Galaxy" },
    .{ .d = "NGC 6503", .name = "Lost-in-Space Galaxy" },
    .{ .d = "IC 2574", .name = "Coddington's Nebula" },
    .{ .d = "UGC 10214", .name = "Tadpole Galaxy" },
    .{ .d = "NGC 2169", .name = "37 Cluster" },
    .{ .d = "NGC 3293", .name = "Gem Cluster" },
    .{ .d = "NGC 6811", .name = "Hole in a Cluster" },
    .{ .d = "NGC 6819", .name = "Foxhead Cluster" },
    .{ .d = "NGC 6939", .name = "Ghost Bush Cluster" },
    .{ .d = "NGC 7789", .name = "Caroline's Rose" },
    .{ .d = "Mel 20", .name = "Alpha Persei Cluster" },
    .{ .d = "Mel 111", .name = "Coma Star Cluster" },
    .{ .d = "Cr 399", .name = "Coathanger" },
};

fn normEq(a: []const u8, b: []const u8) bool {
    var ba: [96]u8 = undefined;
    var bb: [96]u8 = undefined;
    const na = normalize(a, &ba) catch return false;
    const nb = normalize(b, &bb) catch return false;
    return std.mem.eql(u8, na, nb);
}

fn anyMatch(designations: []const []const u8, target: []const u8) bool {
    for (designations) |d| {
        if (normEq(d, target)) return true;
    }
    return false;
}

/// Caldwell number for any of the given designations.
pub fn caldwellNumber(designations: []const []const u8) ?u32 {
    for (CALDWELL) |c| {
        for (c.designations) |cd| {
            if (anyMatch(designations, cd)) return c.n;
        }
    }
    return null;
}

/// For a "C 7" / "Caldwell 7" style query, the designation to look up.
pub fn caldwellTarget(query: []const u8) ?[]const u8 {
    var b: [96]u8 = undefined;
    const n = normalize(query, &b) catch return null;
    if (n.len < 2 or n[0] != 'C') return null;
    const num = std.fmt.parseInt(u32, n[1..], 10) catch return null;
    for (CALDWELL) |c| {
        if (c.n == num) return c.designations[0];
    }
    return null;
}

/// Curated popular name for an object with these designations: the built-in
/// tables (user names file support to come with the Resolver).
pub fn popularName(designations: []const []const u8) ?[]const u8 {
    for (CALDWELL) |c| {
        if (c.name) |nm| {
            for (c.designations) |cd| {
                if (anyMatch(designations, cd)) return nm;
            }
        }
    }
    for (POPULAR_NAMES) |p| {
        if (anyMatch(designations, p.d)) return p.name;
    }
    return null;
}

const testing = std.testing;

test "caldwell lookups" {
    try testing.expectEqual(@as(?u32, 7), caldwellNumber(&.{"NGC 2403"}));
    try testing.expectEqual(@as(?u32, 14), caldwellNumber(&.{ "UGC 454", "NGC  884" }));
    try testing.expectEqual(@as(?u32, null), caldwellNumber(&.{"NGC 224"}));
    try testing.expectEqualStrings("NGC 2403", caldwellTarget("C7").?);
    try testing.expectEqualStrings("IC 342", caldwellTarget("Caldwell 5").?);
    try testing.expectEqualStrings("NGC 869", caldwellTarget("C 14").?);
    try testing.expectEqual(@as(?[]const u8, null), caldwellTarget("C 110"));
    try testing.expectEqual(@as(?[]const u8, null), caldwellTarget("NGC 7"));
    try testing.expectEqual(@as(usize, 109), CALDWELL.len);
    for (CALDWELL, 0..) |c, i| {
        try testing.expectEqual(@as(u32, @intCast(i + 1)), c.n);
        try testing.expect(c.designations.len != 0);
    }
}

test "names" {
    try testing.expectEqualStrings("Hidden Galaxy", popularName(&.{"IC 342"}).?);
    try testing.expectEqual(@as(?[]const u8, null), popularName(&.{"NGC 2403"}));
    try testing.expectEqualStrings("Soul Nebula", popularName(&.{"IC 1848"}).?);
    try testing.expectEqualStrings("Orion Nebula", popularName(&.{"M  42"}).?);
    try testing.expectEqualStrings("Golden Eye Cluster", popularName(&.{ "NGC 2682", "M 67" }).?);
    try testing.expectEqualStrings("Northern Lagoon Nebula", popularName(&.{"SH 2-158"}).?);
    try testing.expectEqualStrings("Leo Triplet", popularName(&.{"M 65"}).?);
    try testing.expectEqualStrings("War and Peace Nebula", popularName(&.{"NGC 6357"}).?);
    try testing.expectEqualStrings("Bear's Paw Galaxy", popularName(&.{"NGC 2537"}).?);
    for (POPULAR_NAMES) |p| {
        const ok = std.mem.startsWith(u8, p.d, "M ") or std.mem.startsWith(u8, p.d, "NGC ") or
            std.mem.startsWith(u8, p.d, "IC ") or std.mem.startsWith(u8, p.d, "Sh2-") or
            std.mem.startsWith(u8, p.d, "Barnard ") or std.mem.startsWith(u8, p.d, "LDN ") or
            std.mem.startsWith(u8, p.d, "vdB ") or std.mem.startsWith(u8, p.d, "UGC ") or
            std.mem.startsWith(u8, p.d, "Mel ") or std.mem.startsWith(u8, p.d, "Cr ");
        try testing.expect(ok);
    }
    try testing.expectEqual(@as(?[]const u8, null), popularName(&.{"NGC 9999"}));
}
