/* NextBSDStatusBar: NSStatusBar and NSStatusItem on WindowServer.

   Copyright (C) 2026 Joseph Maloney

   This file is part of the GNUstep Backend.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; see the file COPYING.LIB.
   If not, see <http://www.gnu.org/licenses/> or write to the
   Free Software Foundation, 51 Franklin Street, Fifth Floor,
   Boston, MA 02110-1301, USA.
*/

/*
 * Status items (nextbsd/libs-back#41), on servers with
 * WS_SERVER_STATUS_ITEMS ("The menu bar" in WSProtocol.h). As on macOS,
 * each NSStatusItem is a small window of its app's own, at the right
 * end of the menu bar, and WindowServer places the items of every app
 * side by side there (ws_status_item()), right to left, and hides them
 * while there is no menu bar (the NeXT and in-window styles).
 *
 * libs-gui's +[NSStatusBar systemStatusBar] answers nil and its
 * NSStatusItem only keeps its properties. The backend gives NSStatusBar
 * a +systemStatusBar of its own when the server has status items: a
 * NextBSDStatusBar, whose -statusItemWithLength: makes
 * NextBSDStatusItems. libs-gui is unchanged.
 *
 * An item is drawn as the Mac menu bar is: a horizontal NSMenuView (in
 * the menu window of an NSMenu of its own) with one item, which has the
 * status item's title or image and its menu as the submenu. So the
 * theme draws it like the app's bar, in the bar's height and colours,
 * and libs-gui's menu tracking opens the menu below it (on the pop-up
 * level, -_serverLevel:), keeps the item highlighted while the menu is
 * open, and closes it as it closes the bar's menus. An item without a
 * menu sends its action to its target, with the item as the sender.
 *
 * Its width is the item's length, or for NSVariableStatusItemLength
 * what the menu view needs for the title or image, and the bar's
 * thickness for NSSquareStatusItemLength. A press on an item activates
 * nothing: the active app and its bar stay, and the app the item
 * belongs to may grab the pointer for the menu (-_updatePopupGrab)
 * without being active. Its windows don't hide when the app is
 * deactivated.
 */

#include "config.h"
#include <AppKit/NSApplication.h>
#include <AppKit/NSEvent.h>
#include <AppKit/NSGraphics.h>
#include <AppKit/NSImage.h>
#include <AppKit/NSInterfaceStyle.h>
#include <AppKit/NSMenu.h>
#include <AppKit/NSMenuItem.h>
#include <AppKit/NSMenuView.h>
#include <AppKit/NSPanel.h>
#include <AppKit/NSStatusBar.h>
#include <AppKit/NSStatusItem.h>
#include <AppKit/NSWindow.h>
#include <Foundation/NSArray.h>
#include <Foundation/NSDate.h>
#include <Foundation/NSDebug.h>
#include <Foundation/NSMapTable.h>
#include <Foundation/NSNotification.h>
#include <GNUstepGUI/GSDisplayServer.h>

#include <errno.h>
#include <math.h>
#include <string.h>
#include <objc/runtime.h>

#include "nextbsd/NextBSDServer.h"

/* libs-gui's own initializer, which -statusItemWithLength: uses. */
@interface NSStatusItem (NextBSDPrivate)
- (id) _initForStatusBar: (NSStatusBar *)bar withLength: (CGFloat)len;
@end

@interface NextBSDStatusItem : NSStatusItem
{
  NSMenu	*holder;	/* the one-item horizontal menu drawn */
  NSMenuItem	*button;	/* its item */
  NSMenu	*itemMenu;	/* the status item's menu */
  BOOL		 shown;
  BOOL		 removed;	/* -[NSStatusBar removeStatusItem:] */
  NSInteger	 priority;	/* -setStatusItemPriority: */
}
- (void) setStatusItemPriority: (NSInteger)priority;
- (NSInteger) statusItemPriority;
- (void) _remove;
- (void) _pressed: (NSEvent *)e;
- (void) _closeMenu;
@end

@interface NextBSDStatusBar : NSStatusBar
{
  NSMutableArray *statusItems;
}
- (void) _closeMenus;
@end

static NextBSDStatusBar *systemBar = nil;

static NextBSDServer *
server(void)
{
  id srv = GSCurrentServer();

  return [srv isKindOfClass: [NextBSDServer class]] ? srv : nil;
}

/*
 * A click in a window of an inactive app activates it
 * (-[NSWindow sendEvent:]), which would swap the menu bar for this
 * app's. The items' windows are libs-gui's menu windows (NSMenuPanel,
 * private to libs-gui) turned into a subclass made here at run time,
 * which hands a press straight to the menu view instead.
 */
static Class statusPanelClass = Nil;
static IMP   panelSendEvent = NULL;

static NSMapTable *itemsByWindow = NULL;	/* NSWindow -> its item */

static void
statusPanelSendEvent(NSWindow *self, SEL cmd, NSEvent *e)
{
  NextBSDStatusItem *item;

  item = itemsByWindow != NULL ? NSMapGet(itemsByWindow, self) : nil;
  if ([e type] == NSLeftMouseDown && item != nil)
    {
      [item _pressed: e];
      return;
    }
  ((void (*)(id, SEL, NSEvent *))panelSendEvent)(self, cmd, e);
}

static void
makeStatusPanelClass(void)
{
  Class menuPanel = NSClassFromString(@"NSMenuPanel");

  if (statusPanelClass != Nil || menuPanel == Nil)
    return;
  /* From the method list: the dispatch table may not be set up yet. */
  panelSendEvent = method_getImplementation(
    class_getInstanceMethod(menuPanel, @selector(sendEvent:)));
  statusPanelClass = objc_allocateClassPair(menuPanel,
					    "NextBSDStatusItemPanel", 0);
  if (statusPanelClass == Nil)
    return;
  class_addMethod(statusPanelClass, @selector(sendEvent:),
		  (IMP)statusPanelSendEvent,
		  method_getTypeEncoding(class_getInstanceMethod(menuPanel,
						@selector(sendEvent:))));
  objc_registerClassPair(statusPanelClass);
}

/* The replacement for +[NSStatusBar systemStatusBar]. */
static id
nextbsdSystemStatusBar(id cls, SEL sel)
{
  if (systemBar == nil)
    systemBar = [NextBSDStatusBar new];
  return systemBar;
}

@implementation NextBSDStatusBar

- (id) init
{
  if ((self = [super init]) != nil)
    statusItems = [NSMutableArray new];
  return self;
}

- (void) dealloc
{
  RELEASE(statusItems);
  [super dealloc];
}

- (NSStatusItem *) statusItemWithLength: (CGFloat)length
{
  NextBSDStatusItem *item;

  item = [[NextBSDStatusItem alloc] _initForStatusBar: self
					    withLength: length];
  [statusItems addObject: item];
  return AUTORELEASE(item);
}

- (void) removeStatusItem: (NSStatusItem *)item
{
  if ([item isKindOfClass: [NextBSDStatusItem class]])
    [(NextBSDStatusItem *)item _remove];
  [statusItems removeObjectIdenticalTo: item];
}

- (CGFloat) thickness
{
  return [NSMenuView menuBarHeight];
}

- (void) _closeMenus
{
  [statusItems makeObjectsPerformSelector: @selector(_closeMenu)];
}

@end

@implementation NextBSDStatusItem

- (id) _initForStatusBar: (NSStatusBar *)bar withLength: (CGFloat)len
{
  NSMenuView *view;
  NSPanel    *win;

  holder = [[NSMenu alloc] initWithTitle: @""];
  [holder setAutoenablesItems: NO];
  button = [[NSMenuItem alloc] initWithTitle: @""
				      action: @selector(_buttonClicked:)
			       keyEquivalent: @""];
  [button setTarget: self];
  [holder addItem: button];
  view = [[NSMenuView alloc] initWithFrame: NSZeroRect];
  [view setHorizontal: YES];
  [view setInterfaceStyle: NSMacintoshInterfaceStyle];
  [holder setMenuRepresentation: view];
  RELEASE(view);
  win = (NSPanel *)[holder window];
  /* Same instance variables: only the class changes. */
  if (statusPanelClass != Nil
      && [win class] == class_getSuperclass(statusPanelClass))
    {
      object_setClass(win, statusPanelClass);
      if (itemsByWindow == NULL)
	itemsByWindow = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
					 NSNonOwnedPointerMapValueCallBacks, 0);
      NSMapInsert(itemsByWindow, win, self);
    }
  [win setLevel: NSStatusWindowLevel];
  [win setHidesOnDeactivate: NO];
  [win setTitle: [[NSProcessInfo processInfo] processName]];
  /* WindowServer gives it the bar's height. */
  [[NSNotificationCenter defaultCenter]
    addObserver: self
       selector: @selector(_windowDidResize:)
	   name: NSWindowDidResizeNotification
	 object: win];
  /* The superclass sets the length, which shows the item (-_update). */
  if ((self = [super _initForStatusBar: bar withLength: len]) != nil)
    [super setTitle: @""];	/* libs-gui's is "?" */
  return self;
}

- (void) dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver: self];
  if (itemsByWindow != NULL)
    NSMapRemove(itemsByWindow, [holder window]);
  [self _remove];
  [button setSubmenu: nil];
  RELEASE(itemMenu);
  RELEASE(button);
  RELEASE(holder);
  [super dealloc];
}

- (void) _remove
{
  NSWindow *win = [holder window];

  removed = YES;
  [NSObject cancelPreviousPerformRequestsWithTarget: self
					   selector: @selector(_update)
					     object: nil];
  if (!shown)
    return;
  shown = NO;
  [server() _setStatusItemWindow: win width: 0];
  [win orderOut: nil];
}

/* The width WindowServer gives the item. */
- (CGFloat) _width
{
  CGFloat len = [self length];

  if (len == NSSquareStatusItemLength)
    return [[self statusBar] thickness];
  if (len > 0)
    return ceil(len);
  /* The menu view puts its item 8 points in (and doesn't size itself
     when it's horizontal): as much again on the right. */
  return ceil(NSMaxX([[holder menuRepresentation] rectOfItemAtIndex: 0])
	      + 8);
}

/* Changes made together (a new item's image, menu and length) show
   together, once the app is back in the run loop: WindowServer places
   the item once for them. */
- (void) _setNeedsUpdate
{
  [NSObject cancelPreviousPerformRequestsWithTarget: self
					   selector: @selector(_update)
					     object: nil];
  [self performSelector: @selector(_update) withObject: nil afterDelay: 0];
}

- (void) _update
{
  NSWindow *win = [holder window];
  NSRect    frame;
  NSImage  *image;
  NSString *title;

  if (removed)
    return;
  image = [self image];
  title = [self title];
  [button setImage: image];
  if ([[self attributedTitle] length] > 0)
    [button setAttributedTitle: [self attributedTitle]];
  else
    [button setTitle: title != nil ? title : @""];
  [button setEnabled: [self isEnabled]];
  [button setToolTip: [self toolTip]];
  if ([button submenu] != itemMenu)
    {
      [button setSubmenu: nil];
      if (itemMenu != nil)
	[button setSubmenu: itemMenu];
      /* Without a submenu a click sends the action. */
      [button setAction: itemMenu == nil ? @selector(_buttonClicked:) : NULL];
    }

  [[holder menuRepresentation] setNeedsSizing: YES];
  [holder sizeToFit];
  frame = [win frame];
  frame.size.width = [self _width];
  frame.size.height = [[self statusBar] thickness];
  [win setFrame: frame display: NO];
  [self _layOut];

  /* WindowServer places the window once it's an item (and ordered
     in), so it is never seen anywhere else. */
  [server() _setStatusItemWindow: win width: NSWidth(frame)];
  if (!shown)
    {
      shown = YES;
      [win orderFrontRegardless];
    }
  [win display];
}

/* The menu view fills the window, its item in the middle (it starts it
   8 points in, which a square item hasn't room for). */
- (void) _layOut
{
  NSMenuView *view = [holder menuRepresentation];
  NSRect	  bounds = [[[holder window] contentView] bounds];
  NSRect	  cell = [view rectOfItemAtIndex: 0];
  CGFloat     dx;

  dx = floor((NSWidth(bounds) - NSWidth(cell)) / 2) - NSMinX(cell);
  [view setFrame: NSMakeRect(dx, 0, NSWidth(bounds) - dx,
			     NSHeight(bounds))];
}

/*
 * Where the item goes among every app's items, for the system's own
 * (the clock, the Dock's extras): WindowServer puts larger priorities
 * further right (WS_STATUS_PRIORITY_* in WSTypes.h: 0 for apps, the
 * default, 1000 for the system's items, 2000 for the clock), and equal
 * ones in the order they first came. Not in libs-gui's NSStatusItem, so
 * an app declares it and asks first:
 *
 *   @interface NSStatusItem (NextBSD)
 *   - (void) setStatusItemPriority: (NSInteger)priority;
 *   @end
 *
 *   if ([item respondsToSelector: @selector(setStatusItemPriority:)])
 *     [item setStatusItemPriority: 2000];
 *
 * Best set before the item has an image or title, so it shows in its
 * place from the start.
 */
- (void) setStatusItemPriority: (NSInteger)p
{
  if (p == priority)
    return;
  priority = p;
  [server() _sendStatusItem: [server() windowWithNumber:
				   [[holder window] windowNumber]]];
}

- (NSInteger) statusItemPriority
{
  return priority;
}

- (void) _windowDidResize: (NSNotification *)n
{
  [self _layOut];
  [[holder window] display];
}

/*
 * A press on the item. libs-gui's -[NSWindow sendEvent:] would activate
 * an inactive app first, so the window hands it here instead. With a
 * menu, the menu view tracks it as the bar's menus are tracked. Without
 * one, the item stays highlighted while the button is down and sends
 * its action if it's let go over the item (libs-gui's horizontal menus
 * wait for a second click on an item without a submenu).
 */
- (void) _pressed: (NSEvent *)e
{
  NSMenuView *view = [holder menuRepresentation];
  NSWindow   *win = [holder window];
  BOOL	      inside = YES;

  if (![self isEnabled])
    return;
  if (itemMenu != nil)
    {
      [view mouseDown: e];
      return;
    }
  [view setHighlightedItemIndex: 0];
  [win display];
  do
    {
      e = [NSApp nextEventMatchingMask: NSLeftMouseUpMask
	     | NSLeftMouseDraggedMask
			     untilDate: [NSDate distantFuture]
				inMode: NSEventTrackingRunLoopMode
			       dequeue: YES];
      inside = NSPointInRect([e locationInWindow],
			     [[win contentView] bounds]);
      if ([view highlightedItemIndex] != (inside ? 0 : -1))
	{
	  [view setHighlightedItemIndex: inside ? 0 : -1];
	  [win display];
	}
    }
  while ([e type] != NSLeftMouseUp);
  [view setHighlightedItemIndex: -1];
  [win display];
  if (inside)
    [self _buttonClicked: self];
}

- (void) _closeMenu
{
  NSMenuView *view = [holder menuRepresentation];

  if ([holder attachedMenu] == nil)
    return;
  [view setHighlightedItemIndex: -1];
  [view detachSubmenu];
  if ([holder attachedMenu] != nil)
    [[holder attachedMenu] close];
}

- (void) _buttonClicked: (id)sender
{
  SEL action = [self action];

  if (action != NULL)
    [NSApp sendAction: action to: [self target] from: self];
}

- (void) setLength: (CGFloat)len
{
  [super setLength: len];
  [self _setNeedsUpdate];
}

- (void) setTitle: (NSString *)title
{
  [super setTitle: title];
  [self _setNeedsUpdate];
}

- (void) setAttributedTitle: (NSAttributedString *)title
{
  [super setAttributedTitle: title];
  [self _setNeedsUpdate];
}

- (void) setImage: (NSImage *)image
{
  [super setImage: image];
  [self _setNeedsUpdate];
}

- (void) setEnabled: (BOOL)flag
{
  [super setEnabled: flag];
  [self _setNeedsUpdate];
}

- (void) setToolTip: (NSString *)toolTip
{
  [super setToolTip: toolTip];
  [self _setNeedsUpdate];
}

/* The menu is the holder item's submenu, which a menu can be of only
   one item: libs-gui's own copy of the status item's item leaves it. */
- (NSMenu *) menu
{
  return itemMenu;
}

- (void) setMenu: (NSMenu *)menu
{
  ASSIGN(itemMenu, menu);
  [self _setNeedsUpdate];
}

- (void) popUpStatusItemMenu: (NSMenu *)menu
{
  NSMenuView *view = [holder menuRepresentation];
  NSWindow   *win = [holder window];
  NSMenu     *old = RETAIN(itemMenu);
  NSEvent    *e;

  /* As a click on the item would: its menu, or this one, below it. */
  if (menu != nil && menu != itemMenu)
    {
      [self setMenu: menu];
      [self _update];
    }
  e = [NSEvent mouseEventWithType: NSLeftMouseDown
			 location: NSMakePoint(NSMidX([view frame]),
					       NSMidY([view frame]))
		    modifierFlags: 0
			timestamp: 0
		     windowNumber: [win windowNumber]
			  context: nil
		      eventNumber: 0
		       clickCount: 1
			 pressure: 1.0];
  [view mouseDown: e];
  if (menu != nil && menu != old)
    {
      [self setMenu: old];
      [self _update];
    }
  RELEASE(old);
}

@end

@implementation NextBSDServer (StatusItems)

- (void) _setUpStatusItems
{
#ifdef WS_SERVER_STATUS_ITEMS
  Method m;

  if ((ws_server_flags(conn) & WS_SERVER_STATUS_ITEMS) == 0)
    return;
  m = class_getClassMethod([NSStatusBar class], @selector(systemStatusBar));
  if (m == NULL)
    return;
  makeStatusPanelClass();
  method_setImplementation(m, (IMP)nextbsdSystemStatusBar);
  statusItemWidths = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
				      NSIntMapValueCallBacks, 0);
  NSDebugLLog(@"NextBSD", @"status items on WindowServer");
#endif
}

- (void) _tearDownStatusItems
{
  if (statusItemWidths != NULL)
    NSFreeMapTable(statusItemWidths);
  statusItemWidths = NULL;
}

- (void) _setStatusItemWindow: (NSWindow *)win width: (CGFloat)width
{
  int n = (int)ceil(width);

  if (statusItemWidths == NULL || win == nil)
    return;
  if (n > 0)
    NSMapInsert(statusItemWidths, win, (void *)(intptr_t)n);
  else
    NSMapRemove(statusItemWidths, win);
  /* A window that isn't made yet becomes an item when it's ordered in
     (-_sendStatusItem:). */
  [self _sendStatusItem: [self windowWithNumber: [win windowNumber]]];
}

- (void) _closeStatusItemMenus
{
  [systemBar _closeMenus];
}

- (BOOL) _isStatusItem: (nextbsd_window_t *)w
{
  NSWindow *win;

  if (w == NULL || statusItemWidths == NULL)
    return NO;
  win = GSWindowWithNumber(w->number);
  return w->statusWidth > 0
    || (win != nil && NSMapGet(statusItemWidths, win) != NULL);
}

- (void) _sendStatusItem: (nextbsd_window_t *)w
{
#ifdef WS_SERVER_STATUS_ITEMS
  NSWindow	    *win;
  NextBSDStatusItem *item;
  int		     width, priority;

  if (w == NULL || statusItemWidths == NULL)
    return;
  win = GSWindowWithNumber(w->number);
  width = win != nil ? (int)(intptr_t)NSMapGet(statusItemWidths, win) : 0;
  item = (win != nil && itemsByWindow != NULL)
    ? NSMapGet(itemsByWindow, win) : nil;
  priority = item != nil ? (int)[item statusItemPriority]
    : WS_STATUS_PRIORITY_APP;
  if (width == w->statusWidth && (width == 0 || priority == w->statusPriority))
    return;
  w->statusWidth = width;
  w->statusPriority = priority;
  NSDebugLLog(@"NextBSD", @"window %d: status item %d points wide, "
	      @"priority %d", w->number, width, priority);
  if (ws_status_item(conn, w->number, (uint32_t)width, priority) != 0)
    NSDebugLLog(@"NextBSD", @"status item: %s", strerror(errno));
#endif
}

@end
