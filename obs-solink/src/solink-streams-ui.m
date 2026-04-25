/*
 solink-streams-ui.m — OBS Tools menu: "SOLink Streams…"
 =========================================================
 An NSPanel (floating, non-activating) that lets the user:
   • See all active SOLink streams (name + source)
   • Add a new stream (choose name + source from scenes/sources)
   • Remove an existing stream
   • The stream list is preserved across menu opens (module-level state)

 Each "stream" is an obs_output_t of type "solink_output" configured
 with a server name and source type/name.
*/

#import <AppKit/AppKit.h>
#include <obs-module.h>
#include <obs-frontend-api.h>
#include "solink-output.h"

// ─── C helper for obs_enum_sources ───────────────────────────────────────────

struct solink_enum_ctx {
    NSMutableArray *labels;
    NSMutableArray *types;
    NSMutableArray *names;
};

static bool solink_enum_source_cb(void *param, obs_source_t *src)
{
    struct solink_enum_ctx *ctx = param;
    uint32_t caps = obs_source_get_output_flags(src);
    if (caps & OBS_SOURCE_VIDEO) {
        const char *sname = obs_source_get_name(src);
        if (sname) {
            NSString *ns = [NSString stringWithUTF8String:sname];
            [ctx->labels addObject:[NSString stringWithFormat:@"Source: %@", ns]];
            [ctx->types  addObject:@3];
            [ctx->names  addObject:ns];
        }
    }
    return true;
}

// ─── Stream record ────────────────────────────────────────────────────────────

@interface SOLinkStreamRecord : NSObject
@property (nonatomic, copy)   NSString    *name;
@property (nonatomic, assign) int          sourceType;   // solink_source_type_t
@property (nonatomic, copy)   NSString    *sourceName;  // empty for main/preview
@property (nonatomic, assign) obs_output_t *output;     // OBS output (retained by OBS)
@end

@implementation SOLinkStreamRecord
- (NSString *)sourceDescription {
    switch (self.sourceType) {
        case 0:  return @"Main Output";
        case 1:  return @"Preview";
        default: return self.sourceName.length ? self.sourceName : @"—";
    }
}
@end

// ─── Window controller ────────────────────────────────────────────────────────

@interface SOLinkStreamsController : NSObject <NSTableViewDelegate, NSTableViewDataSource>

@property (nonatomic, strong) NSPanel      *panel;
@property (nonatomic, strong) NSTableView  *tableView;
@property (nonatomic, strong) NSButton     *removeButton;
@property (nonatomic, strong) NSMutableArray<SOLinkStreamRecord *> *streams;

+ (instancetype)shared;
- (void)showPanel;

@end

@implementation SOLinkStreamsController

+ (instancetype)shared {
    static SOLinkStreamsController *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _streams = [NSMutableArray array];
        [self buildUI];
    }
    return self;
}

// ─── Build UI ────────────────────────────────────────────────────────────────

- (void)buildUI {
    NSRect frame = NSMakeRect(0, 0, 520, 340);
    _panel = [[NSPanel alloc]
              initWithContentRect:frame
                        styleMask:NSWindowStyleMaskTitled
                                | NSWindowStyleMaskClosable
                                | NSWindowStyleMaskResizable
                          backing:NSBackingStoreBuffered
                            defer:NO];
    _panel.title = @"SOLink Streams";
    _panel.floatingPanel = YES;
    _panel.becomesKeyOnlyIfNeeded = YES;

    NSView *content = _panel.contentView;

    // ── Table ─────────────────────────────────────────────────────────────────
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(12, 50, frame.size.width - 24, frame.size.height - 70)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;

    _tableView = [[NSTableView alloc] init];

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.title = @"Stream Name";
    nameCol.minWidth = 180;
    nameCol.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:nameCol];

    NSTableColumn *srcCol = [[NSTableColumn alloc] initWithIdentifier:@"source"];
    srcCol.title = @"Source";
    srcCol.minWidth = 160;
    srcCol.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:srcCol];

    NSTableColumn *statusCol = [[NSTableColumn alloc] initWithIdentifier:@"status"];
    statusCol.title = @"Status";
    statusCol.width = 80;
    statusCol.minWidth = 60;
    [_tableView addTableColumn:statusCol];

    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.allowsMultipleSelection = NO;
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    [_tableView sizeLastColumnToFit];
    scroll.documentView = _tableView;
    [content addSubview:scroll];

    // ── Buttons ───────────────────────────────────────────────────────────────
    NSButton *addBtn = [NSButton buttonWithTitle:@"+ Add Stream"
                                         target:self
                                         action:@selector(addStream:)];
    addBtn.frame = NSMakeRect(12, 12, 130, 28);
    addBtn.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:addBtn];

    _removeButton = [NSButton buttonWithTitle:@"− Remove"
                                       target:self
                                       action:@selector(removeStream:)];
    _removeButton.frame = NSMakeRect(150, 12, 100, 28);
    _removeButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    _removeButton.enabled = NO;
    [content addSubview:_removeButton];

    NSTextField *hint = [NSTextField labelWithString:
        @"Streams are announced to SyphonOut automatically."];
    hint.frame = NSMakeRect(260, 16, frame.size.width - 272, 20);
    hint.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = [NSColor secondaryLabelColor];
    [content addSubview:hint];

    [_tableView.target self];
    [_tableView setTarget:self];
    [_tableView setAction:@selector(tableClicked:)];
}

// ─── Show ─────────────────────────────────────────────────────────────────────

- (void)showPanel {
    [_tableView reloadData];
    if (!_panel.isVisible) {
        [_panel center];
    }
    [_panel orderFront:nil];
}

// ─── Table data source ────────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)_streams.count;
}

- (id)tableView:(NSTableView *)tv
objectValueForTableColumn:(NSTableColumn *)col
            row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_streams.count) return @"";
    SOLinkStreamRecord *rec = _streams[row];
    if ([col.identifier isEqualToString:@"name"])   return rec.name;
    if ([col.identifier isEqualToString:@"source"]) return rec.sourceDescription;
    if ([col.identifier isEqualToString:@"status"]) {
        return rec.output && obs_output_active(rec.output) ? @"● Live" : @"○ Stopped";
    }
    return @"";
}

- (void)tableClicked:(id)sender {
    _removeButton.enabled = (_tableView.selectedRow >= 0);
}

// ─── Add stream ──────────────────────────────────────────────────────────────

- (void)addStream:(id)sender {
    // Build source list: Main Output, Preview, then all scenes, then all sources.
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSMutableArray<NSNumber *> *types  = [NSMutableArray array];
    NSMutableArray<NSString *> *names  = [NSMutableArray array];

    [labels addObject:@"Main Output"];
    [types  addObject:@0];
    [names  addObject:@""];

    [labels addObject:@"Preview (Studio Mode)"];
    [types  addObject:@1];
    [names  addObject:@""];

    // Scenes
    struct obs_frontend_source_list scenes = {0};
    obs_frontend_get_scenes(&scenes);
    for (size_t i = 0; i < scenes.sources.num; i++) {
        const char *sname = obs_source_get_name(scenes.sources.array[i]);
        if (sname) {
            [labels addObject:[NSString stringWithFormat:@"Scene: %s", sname]];
            [types  addObject:@2];
            [names  addObject:[NSString stringWithUTF8String:sname]];
        }
    }
    obs_frontend_source_list_free(&scenes);

    // Sources (non-scene, video-capable)
    struct solink_enum_ctx srcCtx = { labels, types, names };
    obs_enum_sources(solink_enum_source_cb, &srcCtx);

    // Build the alert
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Add SOLink Stream";
    alert.informativeText = @"Choose a source and give the stream a name.";
    [alert addButtonWithTitle:@"Add"];
    [alert addButtonWithTitle:@"Cancel"];

    NSView *accView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 70)];

    NSTextField *nameLabel = [NSTextField labelWithString:@"Stream Name:"];
    nameLabel.frame = NSMakeRect(0, 42, 90, 22);
    [accView addSubview:nameLabel];

    NSTextField *nameField = [NSTextField textFieldWithString:@""];
    nameField.frame = NSMakeRect(96, 42, 264, 22);
    nameField.placeholderString = @"e.g. Main Output";
    [accView addSubview:nameField];

    NSTextField *srcLabel = [NSTextField labelWithString:@"Source:"];
    srcLabel.frame = NSMakeRect(0, 10, 90, 22);
    [accView addSubview:srcLabel];

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(96, 10, 264, 22)
                                                      pullsDown:NO];
    for (NSString *label in labels) [popup addItemWithTitle:label];
    [accView addSubview:popup];

    alert.accessoryView = accView;

    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSString *streamName = nameField.stringValue;
    if (streamName.length == 0) streamName = labels[popup.indexOfSelectedItem];

    NSInteger idx = popup.indexOfSelectedItem;
    int srcType   = types[idx].intValue;
    const char *srcNameC = names[idx].UTF8String;

    // Create the OBS output
    obs_output_t *output = solink_output_create_stream(
        streamName.UTF8String, srcType, srcNameC);
    if (!output) {
        NSAlert *err = [[NSAlert alloc] init];
        err.messageText = @"Failed to create stream";
        err.informativeText = @"OBS could not start the output. Check the OBS log for details.";
        [err runModal];
        return;
    }

    SOLinkStreamRecord *rec = [[SOLinkStreamRecord alloc] init];
    rec.name       = [streamName copy];
    rec.sourceType = srcType;
    rec.sourceName = [names[idx] copy];
    rec.output     = output;
    [_streams addObject:rec];
    [_tableView reloadData];
}

// ─── Remove stream ────────────────────────────────────────────────────────────

- (void)removeStream:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_streams.count) return;

    SOLinkStreamRecord *rec = _streams[row];
    if (rec.output) {
        obs_output_stop(rec.output);
        obs_output_release(rec.output);
        rec.output = NULL;
    }
    [_streams removeObjectAtIndex:row];
    [_tableView reloadData];
    _removeButton.enabled = NO;
}

// ─── Cleanup ─────────────────────────────────────────────────────────────────

- (void)stopAll {
    for (SOLinkStreamRecord *rec in _streams) {
        if (rec.output) {
            obs_output_stop(rec.output);
            obs_output_release(rec.output);
            rec.output = NULL;
        }
    }
    [_streams removeAllObjects];
}

@end

// ─── C bridge ────────────────────────────────────────────────────────────────

void solink_streams_ui_show(void *unused)
{
    (void)unused;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SOLinkStreamsController shared] showPanel];
    });
}

void solink_streams_ui_add_initial_stream(const char *name, obs_output_t *output)
{
    SOLinkStreamRecord *rec = [[SOLinkStreamRecord alloc] init];
    rec.name       = [NSString stringWithUTF8String:name ? name : "OBS Main"];
    rec.sourceType = 0;
    rec.sourceName = @"";
    rec.output     = output;
    [[SOLinkStreamsController shared].streams addObject:rec];
}

void solink_streams_ui_stop_all(void)
{
    [[SOLinkStreamsController shared] stopAll];
}
