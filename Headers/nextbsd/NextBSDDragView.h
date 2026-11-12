/*
   NextBSDDragView - drag and drop through the NextBSD WindowServer

   Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>

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
 * Drag and drop on WindowServers with WS_SERVER_DRAG ("Drag and drop" in
 * WindowServer's WSProtocol.h), the way Darwin's window server does it.
 *
 * As the source: -dragImage:... hands the drag to WindowServer
 * (ws_drag_begin) with the image, the operations the source allows onto
 * this app's windows and onto other apps', and the types on the drag
 * pasteboard, which the source filled in gpbs before calling it.
 * WindowServer moves the image with the pointer above every window and
 * the Dock, shows the cursor for what the window under it would take,
 * and says how the drag ended (WS_EVENT_DRAG_END); meanwhile this loop
 * keeps the app's windows up to date and hands drag events for its own
 * windows to them, so drags inside the app work the same way.
 *
 * As a destination: WindowServer sends WS_EVENT_DRAG to windows that
 * take drags (the backend marks windows with views registered for
 * dragged types WS_WINDOW_ACCEPTS_DRAGS). -takeDragEvent: fills in the
 * NSDraggingInfo this object answers with (the drag pasteboard, the
 * operations offered, the location; no source for another app's drag)
 * and posts GSAppKitDraggingEnter, _Update, _Exit or _Drop to the
 * window, so libs-gui calls the NSDraggingDestination methods as usual;
 * the status NSWindow posts back (-postDragEvent:) goes to WindowServer
 * (ws_drag_status).
 *
 * Older WindowServers: GSDragView's own drags, inside the app only.
 */

#ifndef _NextBSDDragView_h_INCLUDE
#define _NextBSDDragView_h_INCLUDE

#include <GNUstepGUI/GSDragView.h>
#include <WindowServer/WSClient.h>

@interface NextBSDDragView : GSDragView
{
  /* the drag this app is the source of */
  uint32_t	 session;
  BOOL		 ended;
  uint32_t	 endOperation;
  uint32_t	 endFlags;
  NSPoint	 endPoint;	/* GNUstep screen coordinates */
}

+ (BOOL) serverDrags;
/* WS_EVENT_DRAG, _DRAG_STATUS and _DRAG_END, from NextBSDServer. */
- (void) takeDragEvent: (const ws_event_t *)event;
@end

#endif /* _NextBSDDragView_h_INCLUDE */
