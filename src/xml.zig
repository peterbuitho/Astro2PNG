//! A small, allocation-light XML reader — enough for XISF headers and the
//! CDS Sesame / SIMBAD responses. Not a general XML parser: no namespaces
//! (prefixes are kept verbatim in tag names), no DTD, no processing beyond
//! `<?xml?>` and `<!-- comments -->`. Entities `&lt; &gt; &amp; &quot; &apos;`
//! and numeric `&#..;` are decoded in text and attribute values.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ MalformedXml, OutOfMemory };

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Node = struct {
    /// Local tag name including any namespace prefix ("Image", "xisf:Image").
    tag: []const u8,
    parent: ?usize,
    attrs: []Attr,
    /// Direct concatenated text content of this element (children's text not
    /// included), entity-decoded, leading/trailing whitespace preserved.
    text: []const u8,
    /// Indices into `Document.nodes` of direct element children.
    children: []usize,

    pub fn attr(self: Node, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }

    pub fn tagName(self: Node) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, self.tag, ':')) |c| return self.tag[c + 1 ..];
        return self.tag;
    }
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []Node,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    pub fn root(self: *const Document) ?*const Node {
        if (self.nodes.len == 0) return null;
        return &self.nodes[0];
    }

    /// Depth-first search for the first element whose local name equals `name`.
    pub fn find(self: *const Document, name: []const u8) ?*const Node {
        for (self.nodes) |*n| {
            if (std.mem.eql(u8, n.tagName(), name)) return n;
        }
        return null;
    }

    /// First element with local name `name` and the given attribute value.
    pub fn findWithAttr(self: *const Document, name: []const u8, attr_name: []const u8, attr_value: []const u8) ?*const Node {
        for (self.nodes) |*n| {
            if (!std.mem.eql(u8, n.tagName(), name)) continue;
            if (n.attr(attr_name)) |v| {
                if (std.mem.eql(u8, v, attr_value)) return n;
            }
        }
        return null;
    }

    pub fn childByName(self: *const Document, parent: *const Node, name: []const u8) ?*const Node {
        for (parent.children) |ci| {
            const n = &self.nodes[ci];
            if (std.mem.eql(u8, n.tagName(), name)) return n;
        }
        return null;
    }
};

const Builder = struct {
    tag: []const u8,
    parent: ?usize,
    attrs: std.ArrayList(Attr),
    text: std.ArrayList(u8),
    children: std.ArrayList(usize),
};

pub fn parse(gpa: Allocator, source: []const u8) Error!Document {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var builders: std.ArrayList(Builder) = .empty;
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);

    var p = Parser{ .s = source, .i = 0 };

    while (p.i < p.s.len) {
        // Text run up to the next '<'.
        const lt = std.mem.indexOfScalarPos(u8, p.s, p.i, '<') orelse {
            p.i = p.s.len;
            break;
        };
        if (lt > p.i and stack.items.len > 0) {
            const raw = p.s[p.i..lt];
            const decoded = try decodeEntities(a, raw);
            try builders.items[stack.items[stack.items.len - 1]].text.appendSlice(a, decoded);
        }
        p.i = lt + 1;
        if (p.i >= p.s.len) return error.MalformedXml;

        switch (p.s[p.i]) {
            '?' => {
                // <?xml ... ?>
                const end = std.mem.indexOfPos(u8, p.s, p.i, "?>") orelse return error.MalformedXml;
                p.i = end + 2;
            },
            '!' => {
                if (std.mem.startsWith(u8, p.s[p.i..], "!--")) {
                    const end = std.mem.indexOfPos(u8, p.s, p.i, "-->") orelse return error.MalformedXml;
                    p.i = end + 3;
                } else if (std.mem.startsWith(u8, p.s[p.i..], "![CDATA[")) {
                    const start = p.i + "![CDATA[".len;
                    const end = std.mem.indexOfPos(u8, p.s, start, "]]>") orelse return error.MalformedXml;
                    if (stack.items.len > 0) {
                        try builders.items[stack.items[stack.items.len - 1]].text.appendSlice(a, p.s[start..end]);
                    }
                    p.i = end + 3;
                } else {
                    // <!DOCTYPE ...> — skip to matching '>'
                    const end = std.mem.indexOfScalarPos(u8, p.s, p.i, '>') orelse return error.MalformedXml;
                    p.i = end + 1;
                }
            },
            '/' => {
                // Closing tag </name>
                p.i += 1;
                const end = std.mem.indexOfScalarPos(u8, p.s, p.i, '>') orelse return error.MalformedXml;
                p.i = end + 1;
                if (stack.items.len == 0) return error.MalformedXml;
                _ = stack.pop();
            },
            else => {
                // Opening tag <name attr="v" ...> or self-closing <name .../>
                const gt = findTagEnd(p.s, p.i) orelse return error.MalformedXml;
                const inner = p.s[p.i..gt]; // between '<' and '>'
                const self_closing = inner.len > 0 and inner[inner.len - 1] == '/';
                const body = if (self_closing) inner[0 .. inner.len - 1] else inner;

                var tok = std.mem.tokenizeAny(u8, body, " \t\r\n");
                const name = tok.next() orelse return error.MalformedXml;

                var b = Builder{
                    .tag = try a.dupe(u8, name),
                    .parent = if (stack.items.len > 0) stack.items[stack.items.len - 1] else null,
                    .attrs = .empty,
                    .text = .empty,
                    .children = .empty,
                };

                // Attributes: name="value" or name='value'
                var rest = body[name.len..];
                while (true) {
                    rest = std.mem.trimStart(u8, rest, " \t\r\n");
                    if (rest.len == 0) break;
                    const eqp = std.mem.indexOfScalar(u8, rest, '=') orelse break;
                    const aname = std.mem.trim(u8, rest[0..eqp], " \t\r\n");
                    rest = std.mem.trimStart(u8, rest[eqp + 1 ..], " \t\r\n");
                    if (rest.len == 0) return error.MalformedXml;
                    const quote = rest[0];
                    if (quote != '"' and quote != '\'') return error.MalformedXml;
                    const close = std.mem.indexOfScalarPos(u8, rest, 1, quote) orelse return error.MalformedXml;
                    const aval = try decodeEntities(a, rest[1..close]);
                    try b.attrs.append(a, .{ .name = try a.dupe(u8, aname), .value = aval });
                    rest = rest[close + 1 ..];
                }

                const idx = builders.items.len;
                try builders.append(a, b);
                if (b.parent) |par| try builders.items[par].children.append(a, idx);

                p.i = gt + 1;
                if (!self_closing) try stack.append(gpa, idx);
            },
        }
    }

    // Freeze builders into Nodes.
    const nodes = try a.alloc(Node, builders.items.len);
    for (builders.items, 0..) |*bld, k| {
        nodes[k] = .{
            .tag = bld.tag,
            .parent = bld.parent,
            .attrs = bld.attrs.items,
            .text = bld.text.items,
            .children = bld.children.items,
        };
    }

    return .{ .arena = arena, .nodes = nodes };
}

const Parser = struct { s: []const u8, i: usize };

/// Find the '>' that closes a start tag, skipping any inside quoted attributes.
fn findTagEnd(s: []const u8, start: usize) ?usize {
    var i = start;
    var quote: u8 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else switch (c) {
            '"', '\'' => quote = c,
            '>' => return i,
            else => {},
        }
    }
    return null;
}

fn decodeEntities(a: Allocator, raw: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try out.append(a, raw[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse {
            try out.append(a, raw[i]);
            i += 1;
            continue;
        };
        const ent = raw[i + 1 .. semi];
        if (std.mem.eql(u8, ent, "lt")) {
            try out.append(a, '<');
        } else if (std.mem.eql(u8, ent, "gt")) {
            try out.append(a, '>');
        } else if (std.mem.eql(u8, ent, "amp")) {
            try out.append(a, '&');
        } else if (std.mem.eql(u8, ent, "quot")) {
            try out.append(a, '"');
        } else if (std.mem.eql(u8, ent, "apos")) {
            try out.append(a, '\'');
        } else if (ent.len > 1 and ent[0] == '#') {
            const cp: u21 = blk: {
                if (ent[1] == 'x' or ent[1] == 'X') {
                    break :blk std.fmt.parseInt(u21, ent[2..], 16) catch {
                        try out.appendSlice(a, raw[i .. semi + 1]);
                        i = semi + 1;
                        continue;
                    };
                }
                break :blk std.fmt.parseInt(u21, ent[1..], 10) catch {
                    try out.appendSlice(a, raw[i .. semi + 1]);
                    i = semi + 1;
                    continue;
                };
            };
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch 0;
            try out.appendSlice(a, buf[0..n]);
        } else {
            try out.appendSlice(a, raw[i .. semi + 1]);
        }
        i = semi + 1;
    }
    return out.items;
}

const testing = std.testing;

test "parse attributes and nesting" {
    var doc = try parse(testing.allocator,
        \\<?xml version="1.0"?>
        \\<xisf version="1.0"><Image geometry="800:500:1" sampleFormat="UInt16">
        \\  <FITSKeyword name="OBJECT" value="'M 31'" comment="x"/>
        \\</Image></xisf>
    );
    defer doc.deinit();

    const img = doc.find("Image").?;
    try testing.expectEqualStrings("800:500:1", img.attr("geometry").?);
    try testing.expectEqualStrings("UInt16", img.attr("sampleFormat").?);
    const kw = doc.childByName(img, "FITSKeyword").?;
    try testing.expectEqualStrings("OBJECT", kw.attr("name").?);
    try testing.expectEqualStrings("'M 31'", kw.attr("value").?);
}

test "entities in text" {
    var doc = try parse(testing.allocator, "<a>1 &lt; 2 &amp; 3 &#65;</a>");
    defer doc.deinit();
    try testing.expectEqualStrings("1 < 2 & 3 A", doc.find("a").?.text);
}
