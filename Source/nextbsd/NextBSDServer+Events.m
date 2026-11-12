/*
   NextBSDServer+Events - WindowServer events to NSEvents

   Copyright (C) 2026 Joseph Maloney

   This file is part of the GNU Objective C Backend Library.

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

#include "config.h"
#include <AppKit/NSApplication.h>
#include <AppKit/NSEvent.h>
#include <AppKit/NSGraphics.h>
#include <AppKit/NSInterfaceStyle.h>
#include <AppKit/NSMenu.h>
#include <AppKit/NSMenuView.h>
#include <AppKit/NSText.h>
#include <AppKit/NSWindow.h>
#include <Foundation/NSDebug.h>
#include <Foundation/NSRunLoop.h>
#include <Foundation/NSString.h>

#include <string.h>

#include "nextbsd/NextBSDServer.h"
#include "nextbsd/NextBSDCairoShmSurface.h"

/* The window WindowServer last made key because we asked it to. */
static int requestedKeyWindow = 0;

#ifdef WS_SERVER_SCROLL_PHASES
/*
 * A scroll event with the phases WindowServer sends for touchpad
 * scrolls (WS_SCROLL_PHASE_*, the NSEventPhase values). libs-gui's
 * NSEvent answers -phase and -momentumPhase with NSEventPhaseNone and
 * has nowhere to keep them, so this subclass does; +mouseEventWithType:
 * allocates the class it is sent to, and copies keep the ivars.
 */
@interface NextBSDScrollEvent : NSEvent
{
  NSEventPhase _wsPhase;
  NSEventPhase _wsMomentumPhase;
}
- (void) _setPhase: (NSEventPhase)phase momentumPhase: (NSEventPhase)momentum;
@end

@implementation NextBSDScrollEvent
- (void) _setPhase: (NSEventPhase)phase momentumPhase: (NSEventPhase)momentum
{
  _wsPhase = phase;
  _wsMomentumPhase = momentum;
}

- (NSEventPhase) phase
{
  return _wsPhase;
}

- (NSEventPhase) momentumPhase
{
  return _wsMomentumPhase;
}
@end
#endif

/* X keysyms (the values xkbcommon uses) the backend needs to know. */
enum {
  KS_ISO_Left_Tab = 0xfe20,
  KS_BackSpace = 0xff08, KS_Tab = 0xff09, KS_Linefeed = 0xff0a,
  KS_Clear = 0xff0b, KS_Return = 0xff0d, KS_Pause = 0xff13,
  KS_Scroll_Lock = 0xff14, KS_Sys_Req = 0xff15, KS_Escape = 0xff1b,
  KS_Home = 0xff50, KS_Left, KS_Up, KS_Right, KS_Down, KS_Page_Up,
  KS_Page_Down, KS_End, KS_Begin,
  KS_Select = 0xff60, KS_Print, KS_Execute, KS_Insert,
  KS_Undo = 0xff65, KS_Redo, KS_Menu, KS_Find,
  KS_Help = 0xff6a, KS_Break,
  KS_Mode_switch = 0xff7e, KS_Num_Lock = 0xff7f,
  KS_KP_First = 0xff80, KS_KP_Enter = 0xff8d,
  KS_KP_F1 = 0xff91, KS_KP_F2, KS_KP_F3, KS_KP_F4,
  KS_KP_Home = 0xff95, KS_KP_Left, KS_KP_Up, KS_KP_Right, KS_KP_Down,
  KS_KP_Page_Up, KS_KP_Page_Down, KS_KP_End, KS_KP_Begin, KS_KP_Insert,
  KS_KP_Delete,
  KS_KP_Last = 0xffbd,
  KS_F1 = 0xffbe, KS_F35 = 0xffe0,
  KS_Shift_L = 0xffe1, KS_Hyper_R = 0xffee,
  KS_Delete = 0xffff
};

static NSUInteger
ns_modifiers(uint32_t m)
{
  NSUInteger flags = 0;

  if (m & WS_MOD_SHIFT)
    flags |= NSShiftKeyMask;
  if (m & WS_MOD_CONTROL)
    flags |= NSControlKeyMask;
  if (m & WS_MOD_ALT)
    flags |= NSAlternateKeyMask;
  if (m & WS_MOD_COMMAND)
    flags |= NSCommandKeyMask;
  if (m & WS_MOD_CAPSLOCK)
    flags |= NSAlphaShiftKeyMask;
  return flags;
}

static BOOL
is_modifier_keysym(uint32_t sym)
{
  return (sym >= KS_Shift_L && sym <= KS_Hyper_R)
    || (sym >= 0xfe01 && sym <= 0xfe13)	/* ISO lock and level shifts */
    || sym == KS_Mode_switch || sym == KS_Num_Lock;
}

/* The character GNUstep expects for a special key, or 0 (same table as
   the X11 server's process_char()). */
static unichar
special_char(uint32_t sym, NSUInteger *flags)
{
  switch (sym)
    {
    case KS_Return:		return NSCarriageReturnCharacter;
    case KS_KP_Enter:		return NSEnterCharacter;
    case KS_Linefeed:		return NSFormFeedCharacter;
    case KS_Tab:		return NSTabCharacter;
    case KS_ISO_Left_Tab:	return NSBackTabCharacter;
    case KS_Escape:		return 0x1b;
    case KS_BackSpace:		return NSDeleteCharacter;
    default:			break;
    }

  *flags |= NSFunctionKeyMask;
  if (sym >= KS_F1 && sym <= KS_F35)
    return NSF1FunctionKey + (sym - KS_F1);
  switch (sym)
    {
    case KS_Delete:
    case KS_KP_Delete:		return NSDeleteFunctionKey;
    case KS_Home:
    case KS_KP_Home:		return NSHomeFunctionKey;
    case KS_Left:
    case KS_KP_Left:		return NSLeftArrowFunctionKey;
    case KS_Right:
    case KS_KP_Right:		return NSRightArrowFunctionKey;
    case KS_Up:
    case KS_KP_Up:		return NSUpArrowFunctionKey;
    case KS_Down:
    case KS_KP_Down:		return NSDownArrowFunctionKey;
    case KS_Page_Up:
    case KS_KP_Page_Up:		return NSPageUpFunctionKey;
    case KS_Page_Down:
    case KS_KP_Page_Down:	return NSPageDownFunctionKey;
    case KS_End:
    case KS_KP_End:		return NSEndFunctionKey;
    case KS_Begin:
    case KS_KP_Begin:		return NSBeginFunctionKey;
    case KS_Insert:
    case KS_KP_Insert:		return NSInsertFunctionKey;
    case KS_KP_F1:		return NSF1FunctionKey;
    case KS_KP_F2:		return NSF2FunctionKey;
    case KS_KP_F3:		return NSF3FunctionKey;
    case KS_KP_F4:		return NSF4FunctionKey;
    case KS_Select:		return NSSelectFunctionKey;
    case KS_Print:		return NSPrintFunctionKey;
    case KS_Execute:		return NSExecuteFunctionKey;
    case KS_Undo:		return NSUndoFunctionKey;
    case KS_Redo:		return NSRedoFunctionKey;
    case KS_Menu:		return NSMenuFunctionKey;
    case KS_Find:		return NSFindFunctionKey;
    case KS_Help:		return NSHelpFunctionKey;
    case KS_Break:		return NSBreakFunctionKey;
    case KS_Scroll_Lock:	return NSScrollLockFunctionKey;
    case KS_Pause:		return NSPauseFunctionKey;
    case KS_Clear:		return NSClearDisplayFunctionKey;
    case KS_Sys_Req:		return NSSysReqFunctionKey;
    default:			break;
    }
  *flags &= ~NSFunctionKeyMask;
  return 0;
}

static NSString *
utf8_string(const char *text, size_t size)
{
  char buf[32];

  if (size >= sizeof(buf))
    size = sizeof(buf) - 1;
  memcpy(buf, text, size);
  buf[size] = '\0';
  if (buf[0] == '\0')
    return nil;
  return [NSString stringWithUTF8String: buf];
}

@implementation NextBSDServer (Events)

- (NSTimeInterval) _timestamp: (const ws_event_t *)ev
{
  return (NSTimeInterval)ev->hdr.time_usec / 1000000.0;
}

- (void) _postAppKit: (int)subtype window: (int)win
{
  NSEvent *e;

  e = [NSEvent otherEventWithType: NSAppKitDefined
			 location: NSZeroPoint
		    modifierFlags: 0
			timestamp: 0
		     windowNumber: win
			  context: GSCurrentContext()
			  subtype: subtype
			    data1: 0
			    data2: 0];
  [self postEvent: e atStart: NO];
}

/* Location in the window, from the screen position and our frame (which
   may be newer than the one WindowServer used for the event). */
- (NSPoint) _locationIn: (nextbsd_window_t *)w sx: (double)sx sy: (double)sy
{
  return NSMakePoint(sx - NSMinX(w->frame),
		     ([self screenHeight] - sy) - NSMinY(w->frame));
}

- (void) _pointerEvent: (const ws_event_t *)ev
{
  const ws_event_pointer_t *p = &ev->u.pointer;
  nextbsd_window_t	   *w = [self windowWithNumber: ev->hdr.window];
  NSEventType		    type;
  NSEvent		   *e;
  NSPoint		    loc;
  float			    dx, dy;
  int			    button = p->button;

  dx = (pointerScreen.x >= 0) ? p->screen_x - pointerScreen.x : 0;
  dy = (pointerScreen.y >= 0) ? p->screen_y - pointerScreen.y : 0;
  pointerScreen = NSMakePoint(p->screen_x, p->screen_y);
  if (w == NULL)
    return;
  pointerWindow = w->number;

  switch (ev->hdr.type)
    {
    case WS_EVENT_MOUSE_DOWN:
      /* WindowServer raised the window (RaiseOnClick); keep our copy of
	 the stacking order in step. */
      if (w->visible && p->buttons == (1u << p->button))
	[self _stackPlace: w op: NSWindowAbove relativeTo: 0];
      type = (button == WS_BUTTON_LEFT) ? NSLeftMouseDown
	: (button == WS_BUTTON_RIGHT) ? NSRightMouseDown : NSOtherMouseDown;
      break;
    case WS_EVENT_MOUSE_UP:
      type = (button == WS_BUTTON_LEFT) ? NSLeftMouseUp
	: (button == WS_BUTTON_RIGHT) ? NSRightMouseUp : NSOtherMouseUp;
      break;
    case WS_EVENT_MOUSE_DRAGGED:
      if (p->buttons & (1u << WS_BUTTON_LEFT))
	{
	  type = NSLeftMouseDragged;
	  button = WS_BUTTON_LEFT;
	}
      else if (p->buttons & (1u << WS_BUTTON_RIGHT))
	{
	  type = NSRightMouseDragged;
	  button = WS_BUTTON_RIGHT;
	}
      else
	{
	  type = NSOtherMouseDragged;
	  button = WS_BUTTON_MIDDLE;
	}
      break;
    case WS_EVENT_MOUSE_MOVED:
    case WS_EVENT_MOUSE_ENTERED:
      type = NSMouseMoved;
      button = 0;
      break;
    case WS_EVENT_MOUSE_EXITED:
      if (pointerWindow == w->number)
	pointerWindow = 0;
      [self _postAppKit: GSAppKitWindowLeave window: w->number];
      return;
    default:
      return;
    }

  loc = [self _locationIn: w sx: p->screen_x sy: p->screen_y];
  e = [NSEvent mouseEventWithType: type
			 location: loc
		    modifierFlags: ns_modifiers(p->modifiers)
			timestamp: [self _timestamp: ev]
		     windowNumber: w->number
			  context: GSCurrentContext()
		      eventNumber: ev->hdr.serial
		       clickCount: p->click_count
			 pressure: (p->buttons != 0) ? 1.0 : 0.0
		     buttonNumber: button
			   deltaX: dx
			   deltaY: dy
			   deltaZ: 0.0];
  [self postEvent: e atStart: NO];
}

#ifdef WS_SERVER_POINTER_GRAB
/*
 * After a click outside the app ended the menu tracking: libs-gui leaves
 * a menu of the Mac menu bar, or of a window's menu bar, open when the
 * click that ends the tracking isn't on a menu (a click in one of the
 * app's own windows does the same). A click on another app or on the
 * desktop means the user is done with it: close it.
 */
- (void) _closeMenuLeftOpen
{
  NSMenu     *main = (NSApp != nil) ? [NSApp mainMenu] : nil;
  NSMenuView *view;

  if (main == nil || [main attachedMenu] == nil
      || NSInterfaceStyleForKey(@"NSMenuInterfaceStyle", nil)
	 == NSNextStepInterfaceStyle)
    return;
  NSDebugLLog(@"NextBSD", @"closing the menu bar's open menu");
  view = (NSMenuView *)[main menuRepresentation];
  if ([view isKindOfClass: [NSMenuView class]])
    {
      [view setHighlightedItemIndex: -1];
      [view detachSubmenu];
    }
  if ([main attachedMenu] != nil)
    [[main attachedMenu] close];
}

/*
 * The first press outside the app's windows while the popup grab was
 * held; WindowServer has ended the grab. If a menu is still open and
 * libs-gui is tracking it, end the tracking with a click at the
 * pointer, which is outside every menu: the menu closes, no item is
 * chosen. The press itself goes on to the window or desktop under it.
 */
- (void) _pointerOutside: (const ws_event_t *)ev
{
  const ws_event_pointer_t *p = &ev->u.pointer;
  nextbsd_window_t	   *w;
  NSPoint		    loc;
  int			    i;

  [self _popupGrabEnded];
  pointerScreen = NSMakePoint(p->screen_x, p->screen_y);
  pointerWindow = 0;
  w = [self _topPopupMenu];
  if (w == NULL || ![[[NSRunLoop currentRunLoop] currentMode]
		      isEqualToString: NSEventTrackingRunLoopMode])
    return;
  NSDebugLLog(@"NextBSD", @"click outside the app: closing menu window %d",
	      w->number);
  loc = NSMakePoint(p->screen_x - NSMinX(w->frame),
		    ([self screenHeight] - p->screen_y) - NSMinY(w->frame));
  for (i = 0; i < 2; i++)
    {
      NSEvent *e;

      e = [NSEvent mouseEventWithType: i == 0 ? NSLeftMouseDown
						: NSLeftMouseUp
			     location: loc
			modifierFlags: 0
			    timestamp: [self _timestamp: ev]
			 windowNumber: w->number
			      context: GSCurrentContext()
			  eventNumber: ev->hdr.serial
			   clickCount: 1
			     pressure: i == 0 ? 1.0 : 0.0
			 buttonNumber: 0
			       deltaX: 0.0
			       deltaY: 0.0
			       deltaZ: 0.0];
      [self postEvent: e atStart: NO];
    }
  /* Once the tracking loop is done with the click. */
  [self performSelector: @selector(_closeMenuLeftOpen)
	     withObject: nil
	     afterDelay: 0.0
		inModes: [NSArray arrayWithObjects: NSDefaultRunLoopMode,
				  NSModalPanelRunLoopMode, nil]];
}
#endif

- (void) _scrollEvent: (const ws_event_t *)ev
{
  const ws_event_scroll_t *s = &ev->u.scroll;
  nextbsd_window_t	  *w = [self windowWithNumber: ev->hdr.window];
  NSEvent		  *e;
  NSPoint		   loc;
  float			   dx, dy;
  Class			   eventCls = [NSEvent class];

  if (w == NULL)
    return;
  /* GNUstep scroll deltas are in lines, positive = up / right. */
  if (s->source == WS_SCROLL_WHEEL && (s->v120_x != 0 || s->v120_y != 0))
    {
      dx = (s->v120_x / 120.0) * scrollMultiplier;
      dy = -(s->v120_y / 120.0) * scrollMultiplier;
    }
  else
    {
      dx = s->dx / scrollPixelsPerLine;
      dy = -s->dy / scrollPixelsPerLine;
    }
  loc = NSMakePoint(s->x, NSHeight(w->frame) - s->y);
#ifdef WS_SERVER_SCROLL_PHASES
  /* Touchpad scrolls: began, changed, ended (with no delta), then
     momentum began, changed, ended. */
  if (s->phase != 0 || s->momentum_phase != 0)
    eventCls = [NextBSDScrollEvent class];
#endif
  e = [eventCls mouseEventWithType: NSScrollWheel
			 location: loc
		    modifierFlags: ns_modifiers(s->modifiers)
			timestamp: [self _timestamp: ev]
		     windowNumber: w->number
			  context: GSCurrentContext()
		      eventNumber: ev->hdr.serial
		       clickCount: 1
			 pressure: 1.0
		     buttonNumber: 0
			   deltaX: dx
			   deltaY: dy
			   deltaZ: 0.0];
#ifdef WS_SERVER_SCROLL_PHASES
  if ([e isKindOfClass: [NextBSDScrollEvent class]])
    [(NextBSDScrollEvent *)e _setPhase: s->phase
			 momentumPhase: s->momentum_phase];
#endif
  [self postEvent: e atStart: NO];
}

- (int) _keyWindowNumber: (const ws_event_t *)ev
{
  if (ev->hdr.window != 0 && GSWindowWithNumber(ev->hdr.window) != nil)
    return ev->hdr.window;
  return [[NSApp keyWindow] windowNumber];
}

- (void) _keyEvent: (const ws_event_t *)ev
{
  const ws_event_key_t *k = &ev->u.key;
  NSUInteger		flags = ns_modifiers(k->modifiers);
  NSString	       *chars;
  NSString	       *plain;
  NSEvent	       *e;
  unichar		c;

  /* Modifier keys arrive as WS_EVENT_FLAGS_CHANGED as well. */
  if (is_modifier_keysym(k->keysym))
    return;
  c = special_char(k->keysym, &flags);
  if (c != 0)
    {
      chars = plain = [NSString stringWithCharacters: &c length: 1];
    }
  else
    {
      chars = utf8_string(k->text, sizeof(k->text));
      plain = utf8_string(k->text_unmodified, sizeof(k->text_unmodified));
      if (chars == nil)
	chars = plain;
      if (plain == nil)
	plain = chars;
      if (chars == nil)
	return;		/* a dead key, or nothing to type */
    }
  if (k->keysym >= KS_KP_First && k->keysym <= KS_KP_Last)
    flags |= NSNumericPadKeyMask;

  e = [NSEvent keyEventWithType: (ev->hdr.type == WS_EVENT_KEY_DOWN)
				   ? NSKeyDown : NSKeyUp
		       location: NSZeroPoint
		  modifierFlags: flags
		      timestamp: [self _timestamp: ev]
		   windowNumber: [self _keyWindowNumber: ev]
			context: GSCurrentContext()
		     characters: chars
    charactersIgnoringModifiers: plain
		      isARepeat: (k->flags & WS_KEY_REPEAT) != 0
			keyCode: k->keycode];
  [self postEvent: e atStart: NO];
}

- (void) _flagsEvent: (const ws_event_t *)ev
{
  NSEvent *e;

  e = [NSEvent keyEventWithType: NSFlagsChanged
		       location: NSZeroPoint
		  modifierFlags: ns_modifiers(ev->u.flags.modifiers)
		      timestamp: [self _timestamp: ev]
		   windowNumber: [self _keyWindowNumber: ev]
			context: GSCurrentContext()
		     characters: @""
    charactersIgnoringModifiers: @""
		      isARepeat: NO
			keyCode: 0];
  [self postEvent: e atStart: NO];
}

- (void) setinputfocus: (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  if (w == NULL || (w->flags & WS_WINDOW_NO_KEY))
    return;
  requestedKeyWindow = w->number;
  ws_window_make_key(conn, w->number);
}

- (void) handleEvent: (const ws_event_t *)ev
{
  nextbsd_window_t *w;

  NSDebugLLog(@"NextBSDEvents", @"%s window %u serial %u",
	      ws_event_name(ev->hdr.type), ev->hdr.window, ev->hdr.serial);
  switch (ev->hdr.type)
    {
    case WS_EVENT_WELCOME:
      [self setScreenInfo: &ev->u.welcome.screen];
      break;

    case WS_EVENT_SCREEN_CHANGED:
      [self _screenChanged: &ev->u.screen];
      break;

#ifdef WS_SERVER_USABLE_AREA
    case WS_EVENT_USABLE_AREA:
      if (ev->u.usable_area.screen_id == screen.screen_id)
	[self _usableAreaChanged: ev->u.usable_area.usable];
      break;
#endif

    case WS_EVENT_APP_ACTIVATED:
      /* WindowServer made us the active app (a click, or another app
	 quit): tell NSApp, without asking WindowServer again. */
      if (NSApp != nil && [NSApp isActive] == NO)
	{
	  serverActivating = YES;
	  NS_DURING
	    [NSApp activateIgnoringOtherApps: YES];
	  NS_HANDLER
	    serverActivating = NO;
	    [localException raise];
	  NS_ENDHANDLER
	  serverActivating = NO;
	}
      break;

    case WS_EVENT_APP_DEACTIVATED:
      /* Another app became active: hide our menus and panels. */
      requestedKeyWindow = 0;
      if (NSApp != nil && [NSApp isActive] == YES)
	{
	  serverDeactivating = YES;
	  NS_DURING
	    [NSApp deactivate];
	  NS_HANDLER
	    serverDeactivating = NO;
	    [localException raise];
	  NS_ENDHANDLER
	  serverDeactivating = NO;
	}
      break;

    case WS_EVENT_KEY_WINDOW_GAINED:
      /* Ignore the answer to our own -setinputfocus:; anything else is
	 WindowServer's choice (a click, or activation). */
      if ((int)ev->hdr.window == requestedKeyWindow)
	{
	  requestedKeyWindow = 0;
	}
      else if (GSWindowWithNumber(ev->hdr.window) != nil)
	{
	  [self _postAppKit: GSAppKitWindowFocusIn window: ev->hdr.window];
	}
      break;

    case WS_EVENT_KEY_WINDOW_LOST:
      /* libs-gui resigns key itself when another window takes it. */
      break;

    case WS_EVENT_WINDOW_FRAME:
      w = [self windowWithNumber: ev->hdr.window];
      if (w != NULL)
	{
	  w->frame = [self nsRectFromWSRect: ev->u.frame.frame];
#ifdef WS_FRAME_TILED
	  [self _window: w
		isTiled: (ev->u.frame.flags & WS_FRAME_TILED) != 0];
#endif
	  /* During a screen change the window hears it with the others,
	     once the change's events are in (-_notifyAllFrames). */
	  if (!screenParamsPending)
	    [self _notifyFrame: w post: YES];
	}
      break;

    case WS_EVENT_WINDOW_RESTORE:
      /* The user double-clicked the window's tile; WindowServer has
	 activated us. Deminiaturize the libs-gui way, so delegates and
	 notifications see it; ordering the window in removes the tile. */
      {
	NSWindow *nswin = GSWindowWithNumber(ev->hdr.window);

	w = [self windowWithNumber: ev->hdr.window];
	if (nswin == nil || w == NULL)
	  break;
	/* With GSSuppressAppIcon, hiding miniaturizes every window, and a
	   hidden app orders no window in: unhiding brings them all back. */
	if ([NSApp isHidden])
	  [NSApp unhide: NSApp];
	if ([nswin isMiniaturized])
	  [nswin deminiaturize: NSApp];
	else if (!w->visible)
	  [nswin makeKeyAndOrderFront: NSApp];
      }
      break;

    case WS_EVENT_BUFFER_RELEASE:
      w = [self windowWithNumber: ev->hdr.window];
      if (w != NULL && w->surface != nil)
	[w->surface bufferReleased: ev->u.buffer.buffer_id];
      break;

    case WS_EVENT_FRAME_DONE:
      w = [self windowWithNumber: ev->hdr.window];
      if (w != NULL && w->surface != nil)
	[w->surface frameDone];
      break;

    case WS_EVENT_MOUSE_DOWN:
    case WS_EVENT_MOUSE_UP:
    case WS_EVENT_MOUSE_MOVED:
    case WS_EVENT_MOUSE_DRAGGED:
    case WS_EVENT_MOUSE_ENTERED:
    case WS_EVENT_MOUSE_EXITED:
      [self _pointerEvent: ev];
      break;

    case WS_EVENT_SCROLL:
      [self _scrollEvent: ev];
      break;

    case WS_EVENT_KEY_DOWN:
    case WS_EVENT_KEY_UP:
      [self _keyEvent: ev];
      break;

    case WS_EVENT_FLAGS_CHANGED:
      [self _flagsEvent: ev];
      break;

#ifdef WS_SERVER_POINTER_GRAB
    case WS_EVENT_POINTER_OUTSIDE:
      [self _pointerOutside: ev];
      break;

    case WS_EVENT_POINTER_UNGRABBED:
      [self _popupGrabEnded];
      break;
#endif

    case WS_EVENT_ERROR:
      NSDebugLLog(@"NextBSD", @"WindowServer error for request %u "
		  @"window %u: %s (%d)", ev->u.error.request, ev->hdr.window,
		  ev->u.error.message, ev->u.error.code);
      break;

    default:
      break;
    }
}

/* ---- the pointer ---- */

- (NSPoint) mouselocation
{
  return [self mouseLocationOnScreen: screen.screen_id window: NULL];
}

- (NSPoint) mouseLocationOnScreen: (int)aScreen window: (int *)win
{
  if (win != NULL)
    *win = pointerWindow;
  if (pointerScreen.x < 0)
    return NSMakePoint(-1, -1);
  return NSMakePoint(pointerScreen.x, [self screenHeight] - pointerScreen.y);
}

- (BOOL) capturemouse: (int)win
{
  /* WindowServer grabs the pointer for the window a button went down in. */
  return YES;
}

- (void) releasemouse
{
}

- (void) setMouseLocation: (NSPoint)mouseLocation onScreen: (int)aScreen
{
  /* Apps can't warp the pointer. */
}

@end
