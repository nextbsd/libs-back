/*
   NextBSDGLContext - NSOpenGLContext for the NextBSD WindowServer

   OpenGL with EGL on GBM, on the GPU WindowServer composites with,
   into GPU buffers (dmabufs) it takes without a copy. See
   NextBSDOpenGL.h for how frames reach the screen.

   Copyright (C) 2026 Joseph Maloney

   Modelled on WaylandGLContext.m.

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
#include <AppKit/NSView.h>
#include <AppKit/NSWindow.h>
#include <Foundation/NSDebug.h>
#include <Foundation/NSException.h>
#include <Foundation/NSHashTable.h>
#include <Foundation/NSRunLoop.h>

#include "nextbsd/NextBSDOpenGL.h"

#ifdef NEXTBSD_HAVE_GL

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <gbm.h>
#include <cairo.h>

#include "nextbsd/NextBSDServer.h"
#include "nextbsd/NextBSDCairoShmSurface.h"

/* GPU buffers came with a newer libWindowServerClient than the server
   flag: without them, there's no OpenGL rather than a missing symbol. */
#pragma weak ws_dmabuf_formats
#pragma weak ws_buffer_create_dmabuf

/* The few GL entry points the backend calls itself, so it needs no GL
   header or library: they come from eglGetProcAddress. */
typedef unsigned int nb_GLenum;
#define NB_GL_UNSIGNED_BYTE	0x1401
#define NB_GL_RGBA		0x1908
#define NB_GL_PACK_ALIGNMENT	0x0D05
#define NB_GL_RENDERER		0x1F01
#define NB_GL_VERSION		0x1F02
#define NB_GL_FRAMEBUFFER	0x8D40
#define NB_GL_FRAMEBUFFER_BINDING 0x8CA6

/* ---- libEGL and libgbm, loaded on first use ---- */

#define EGL_FUNCS(X) \
  X(EGLint, eglGetError, (void)) \
  X(__eglMustCastToProperFunctionPointerType, eglGetProcAddress, \
    (const char *)) \
  X(const char *, eglQueryString, (EGLDisplay, EGLint)) \
  X(EGLBoolean, eglInitialize, (EGLDisplay, EGLint *, EGLint *)) \
  X(EGLBoolean, eglBindAPI, (EGLenum)) \
  X(EGLBoolean, eglChooseConfig, (EGLDisplay, const EGLint *, EGLConfig *, \
    EGLint, EGLint *)) \
  X(EGLBoolean, eglGetConfigAttrib, (EGLDisplay, EGLConfig, EGLint, \
    EGLint *)) \
  X(EGLContext, eglCreateContext, (EGLDisplay, EGLConfig, EGLContext, \
    const EGLint *)) \
  X(EGLBoolean, eglDestroyContext, (EGLDisplay, EGLContext)) \
  X(EGLSurface, eglCreateWindowSurface, (EGLDisplay, EGLConfig, \
    EGLNativeWindowType, const EGLint *)) \
  X(EGLBoolean, eglDestroySurface, (EGLDisplay, EGLSurface)) \
  X(EGLBoolean, eglMakeCurrent, (EGLDisplay, EGLSurface, EGLSurface, \
    EGLContext)) \
  X(EGLContext, eglGetCurrentContext, (void)) \
  X(EGLBoolean, eglSwapBuffers, (EGLDisplay, EGLSurface)) \
  X(EGLBoolean, eglSwapInterval, (EGLDisplay, EGLint))

#define GBM_FUNCS(X) \
  X(struct gbm_device *, gbm_create_device, (int)) \
  X(struct gbm_surface *, gbm_surface_create, (struct gbm_device *, \
    uint32_t, uint32_t, uint32_t, uint32_t)) \
  X(struct gbm_surface *, gbm_surface_create_with_modifiers, \
    (struct gbm_device *, uint32_t, uint32_t, uint32_t, const uint64_t *, \
    const unsigned int)) \
  X(void, gbm_surface_destroy, (struct gbm_surface *)) \
  X(struct gbm_bo *, gbm_surface_lock_front_buffer, (struct gbm_surface *)) \
  X(void, gbm_surface_release_buffer, (struct gbm_surface *, \
    struct gbm_bo *)) \
  X(int, gbm_surface_has_free_buffers, (struct gbm_surface *)) \
  X(int, gbm_bo_get_fd, (struct gbm_bo *)) \
  X(uint32_t, gbm_bo_get_stride, (struct gbm_bo *)) \
  X(uint32_t, gbm_bo_get_offset, (struct gbm_bo *, int)) \
  X(uint64_t, gbm_bo_get_modifier, (struct gbm_bo *)) \
  X(uint32_t, gbm_bo_get_width, (struct gbm_bo *)) \
  X(uint32_t, gbm_bo_get_height, (struct gbm_bo *))

#define GL_FUNCS(X) \
  X(void, glReadPixels, (int, int, int, int, nb_GLenum, nb_GLenum, void *)) \
  X(void, glPixelStorei, (nb_GLenum, int)) \
  X(void, glGetIntegerv, (nb_GLenum, int *)) \
  X(void, glBindFramebuffer, (nb_GLenum, unsigned int)) \
  X(const unsigned char *, glGetString, (nb_GLenum))

#define DECLARE(ret, name, args) static ret (*p_##name) args;
EGL_FUNCS(DECLARE)
GBM_FUNCS(DECLARE)
GL_FUNCS(DECLARE)
#undef DECLARE

/* gbm_surface_create_with_modifiers2 (Mesa 21.3) says how the buffers
   are used; the older call doesn't. Optional. */
static struct gbm_surface *(*p_gbm_surface_create_with_modifiers2)
  (struct gbm_device *, uint32_t, uint32_t, uint32_t, const uint64_t *,
   const unsigned int, uint32_t);
static EGLSurface (*p_eglCreatePlatformWindowSurface)
  (EGLDisplay, EGLConfig, void *, const EGLAttrib *);

/* The process's EGL display, on the render node WindowServer names. */
static struct
{
  BOOL			 tried;
  BOOL			 ok;
  int			 fd;
  struct gbm_device	*gbm;
  EGLDisplay		 display;
  EGLenum		 api;		/* EGL_OPENGL_API or _ES_API */
  BOOL			 surfaceless;	/* EGL_KHR_surfaceless_context */
  ws_dmabuf_formats_t	 formats;	/* what WindowServer composites */
} egl;

/* Every live context, for the window events (not retained). */
static NSHashTable *contexts = nil;
static NextBSDGLContext *currentContext = nil;

/* A buffer of the context's GBM surface, as WindowServer knows it. */
struct nextbsd_gl_buffer
{
  struct gbm_bo	*bo;
  ws_buffer_t	*buffer;
  BOOL		 busy;		/* locked, with WindowServer */
};

/* Mesa's GBM surfaces have at most four buffers. */
#define MAX_GL_BUFFERS 8

static NextBSDServer *
server(void)
{
  id srv = GSCurrentServer();

  return [srv isKindOfClass: [NextBSDServer class]] ? srv : nil;
}

static BOOL
loadLibraries(void)
{
  void *libEGL = dlopen("libEGL.so.1", RTLD_NOW | RTLD_LOCAL);
  void *libgbm = dlopen("libgbm.so.1", RTLD_NOW | RTLD_LOCAL);

  if (libEGL == NULL || libgbm == NULL)
    {
      NSDebugLLog(@"OpenGL", @"NextBSD: no libEGL or libgbm: %s", dlerror());
      return NO;
    }
#define LOAD(lib, ret, name, args) \
  if ((p_##name = (ret (*) args)dlsym(lib, #name)) == NULL) \
    { \
      NSDebugLLog(@"OpenGL", @"NextBSD: no %s", #name); \
      return NO; \
    }
#define LOAD_EGL(ret, name, args) LOAD(libEGL, ret, name, args)
#define LOAD_GBM(ret, name, args) LOAD(libgbm, ret, name, args)
  EGL_FUNCS(LOAD_EGL)
  GBM_FUNCS(LOAD_GBM)
#undef LOAD_EGL
#undef LOAD_GBM
#undef LOAD
  p_gbm_surface_create_with_modifiers2 =
    dlsym(libgbm, "gbm_surface_create_with_modifiers2");
  p_eglCreatePlatformWindowSurface =
    dlsym(libEGL, "eglCreatePlatformWindowSurface");
  return YES;
}

static BOOL
loadGL(void)
{
#define LOAD_GL(ret, name, args) \
  if ((p_##name = (ret (*) args)p_eglGetProcAddress(#name)) == NULL) \
    return NO;
  GL_FUNCS(LOAD_GL)
#undef LOAD_GL
  return YES;
}

static BOOL
hasExtension(const char *list, const char *ext)
{
  size_t len = strlen(ext);
  const char *p = list;

  while (p != NULL && (p = strstr(p, ext)) != NULL)
    {
      if ((p == list || p[-1] == ' ') && (p[len] == ' ' || p[len] == '\0'))
	return YES;
      p += len;
    }
  return NO;
}

/*
 * Set EGL up on WindowServer's render node, once per process. NO means
 * no OpenGL in this app (and pixel formats are nil).
 */
BOOL
NextBSDGLSetUp(void)
{
  NextBSDServer *srv = server();
  ws_connection_t *conn = [srv connection];
  PFNEGLGETPLATFORMDISPLAYEXTPROC getDisplay;
  const char *api = getenv("NB_GL_API");
  const char *exts;
  EGLint major, minor;

  if (egl.tried)
    return egl.ok;
  egl.tried = YES;
  egl.fd = -1;
  if (conn == NULL || ![NextBSDGLContext isAvailable])
    return NO;
  if (ws_dmabuf_formats(conn, &egl.formats) < 0 || egl.formats.count == 0)
    {
      NSDebugLLog(@"OpenGL", @"NextBSD: WindowServer takes no GPU buffers: %s",
		  strerror(errno));
      [srv scheduleDispatch];
      return NO;
    }
  [srv scheduleDispatch];
  if (!loadLibraries())
    return NO;
  egl.fd = open(egl.formats.render_node, O_RDWR | O_CLOEXEC);
  if (egl.fd < 0)
    {
      NSLog(@"NextBSD: OpenGL: can't open %s: %s", egl.formats.render_node,
	    strerror(errno));
      return NO;
    }
  egl.gbm = p_gbm_create_device(egl.fd);
  getDisplay = (PFNEGLGETPLATFORMDISPLAYEXTPROC)
    p_eglGetProcAddress("eglGetPlatformDisplayEXT");
  egl.display = egl.gbm != NULL && getDisplay != NULL
    ? getDisplay(EGL_PLATFORM_GBM_KHR, egl.gbm, NULL) : EGL_NO_DISPLAY;
  if (egl.display == EGL_NO_DISPLAY
      || !p_eglInitialize(egl.display, &major, &minor))
    {
      NSLog(@"NextBSD: OpenGL: no EGL on %s", egl.formats.render_node);
      return NO;
    }
  /* Desktop OpenGL (what NSOpenGLContext code is written for), else
     OpenGL ES 2. */
  egl.api = EGL_OPENGL_API;
  if ((api != NULL && strcmp(api, "gles") == 0)
      || !p_eglBindAPI(EGL_OPENGL_API))
    {
      egl.api = EGL_OPENGL_ES_API;
      if (!p_eglBindAPI(EGL_OPENGL_ES_API))
	{
	  NSLog(@"NextBSD: OpenGL: EGL has neither OpenGL nor OpenGL ES");
	  return NO;
	}
    }
  exts = p_eglQueryString(egl.display, EGL_EXTENSIONS);
  egl.surfaceless = hasExtension(exts, "EGL_KHR_surfaceless_context");
  if (!loadGL())
    {
      NSLog(@"NextBSD: OpenGL: missing GL entry points");
      return NO;
    }
  egl.ok = YES;
  NSDebugLLog(@"OpenGL", @"NextBSD: EGL %d.%d on %s, %s", major, minor,
	      egl.formats.render_node,
	      egl.api == EGL_OPENGL_API ? "OpenGL" : "OpenGL ES");
  return YES;
}

static double
monotonic(void)
{
  struct timespec ts;

  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Handle WindowServer's events for up to ms milliseconds. */
static void
waitForEvents(NextBSDServer *srv, int ms)
{
  ws_connection_t *conn = [srv connection];
  struct pollfd	   pfd;

  if (conn == NULL)
    return;
  [srv dispatchEvents];
  pfd.fd = ws_connection_fd(conn);
  pfd.events = POLLIN;
  if (poll(&pfd, 1, ms) > 0)
    [srv dispatchEvents];
}

/* -[NSView wantsBestResolutionOpenGLSurface], from macOS: a view may
   implement it. */
@protocol NextBSDGLBestResolution
- (BOOL) wantsBestResolutionOpenGLSurface;
@end

@interface NextBSDGLContext (Private)
- (void) _updateDrawable;
- (void) _destroySurface;
- (void) _giveWindowBack;
- (void) _scheduleCallback;
@end

@implementation NextBSDGLContext

+ (BOOL) isAvailable
{
  ws_connection_t *conn = [NextBSDServer connection];

  return conn != NULL && ws_dmabuf_formats != NULL
    && ws_buffer_create_dmabuf != NULL
    && (ws_server_flags(conn) & WS_SERVER_DMABUF) != 0;
}

+ (void) clearCurrentContext
{
  if (egl.ok)
    p_eglMakeCurrent(egl.display, EGL_NO_SURFACE, EGL_NO_SURFACE,
		     EGL_NO_CONTEXT);
  currentContext = nil;
}

+ (NSOpenGLContext *) currentContext
{
  return currentContext;
}

/* ---- events for the windows ---- */

+ (BOOL) bufferReleased: (uint32_t)bufferId
{
  NSHashEnumerator e;
  NextBSDGLContext *c;
  int		    i;

  if (contexts == nil)
    return NO;
  e = NSEnumerateHashTable(contexts);
  while ((c = NSNextHashEnumeratorItem(&e)) != nil)
    {
      for (i = 0; i < c->_bufferCount; i++)
	{
	  struct nextbsd_gl_buffer *b = &c->_buffers[i];

	  if (b->buffer != NULL && ws_buffer_id(b->buffer) == bufferId)
	    {
	      if (b->busy && c->_gbmSurface != NULL)
		p_gbm_surface_release_buffer(c->_gbmSurface, b->bo);
	      b->busy = NO;
	      NSEndHashTableEnumeration(&e);
	      return YES;
	    }
	}
    }
  NSEndHashTableEnumeration(&e);
  return NO;
}

+ (void) frameDoneForWindow: (int)win
{
  NSHashEnumerator e;
  NextBSDGLContext *c;

  if (contexts == nil)
    return;
  e = NSEnumerateHashTable(contexts);
  while ((c = NSNextHashEnumeratorItem(&e)) != nil)
    {
      if (c->_window == win && c->_framePending)
	{
	  c->_framePending = NO;
	  [c _scheduleCallback];
	}
    }
  NSEndHashTableEnumeration(&e);
}

+ (void) windowWillClose: (int)win
{
  NSHashEnumerator e;
  NextBSDGLContext *c;

  if (contexts == nil)
    return;
  e = NSEnumerateHashTable(contexts);
  while ((c = NSNextHashEnumeratorItem(&e)) != nil)
    {
      if (c->_window == win)
	{
	  /* Its window is going: nothing to give back. */
	  c->_owner = NO;
	  [c _destroySurface];
	  c->_window = 0;
	  c->_framePending = NO;
	}
    }
  NSEndHashTableEnumeration(&e);
}

/* ---- creating ---- */

/* An EGL config for the pixel format whose buffers are GBM format
   `visual`. */
static EGLConfig
chooseConfig(NextBSDGLPixelFormat *format, uint32_t *visual)
{
  int	   alpha = [format valueForAttribute: NSOpenGLPFAAlphaSize default: 0];
  int	   samples = [format valueForAttribute: NSOpenGLPFASamples default: 0];
  EGLint   attrs[] = {
    EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
    EGL_RENDERABLE_TYPE,
      egl.api == EGL_OPENGL_API ? EGL_OPENGL_BIT : EGL_OPENGL_ES2_BIT,
    EGL_RED_SIZE, 8,
    EGL_GREEN_SIZE, 8,
    EGL_BLUE_SIZE, 8,
    EGL_ALPHA_SIZE, alpha > 0 ? 8 : 0,
    EGL_DEPTH_SIZE,
      [format valueForAttribute: NSOpenGLPFADepthSize default: 0],
    EGL_STENCIL_SIZE,
      [format valueForAttribute: NSOpenGLPFAStencilSize default: 0],
    EGL_SAMPLES, samples,
    EGL_NONE
  };
  EGLConfig configs[64];
  EGLint    n = 0, i, id;
  int	    pass;

  *visual = alpha > 0 ? GBM_FORMAT_ARGB8888 : GBM_FORMAT_XRGB8888;
  /* Without multisampling if none has the samples asked for. */
  for (pass = 0; pass < 2; pass++)
    {
      if (pass == 1)
	{
	  if (samples == 0)
	    break;
	  attrs[sizeof(attrs) / sizeof(attrs[0]) - 2] = 0;
	}
      if (!p_eglChooseConfig(egl.display, attrs, configs, 64, &n))
	n = 0;
      /* EGL sorts by the sizes; take the first whose buffers are the
	 format, and has no alpha unless asked for. */
      for (i = 0; i < n; i++)
	{
	  if (p_eglGetConfigAttrib(egl.display, configs[i],
				   EGL_NATIVE_VISUAL_ID, &id)
	      && (uint32_t)id == *visual)
	    return configs[i];
	}
    }
  return NULL;
}

- (id) initWithFormat: (NSOpenGLPixelFormat *)format
	 shareContext: (NSOpenGLContext *)share
{
  EGLint     gles[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
  EGLContext shared = EGL_NO_CONTEXT;

  self = [super init];
  if (self == nil)
    return nil;
  if (![format isKindOfClass: [NextBSDGLPixelFormat class]] || !egl.ok)
    {
      NSDebugMLLog(@"OpenGL", @"invalid pixel format %@", format);
      DESTROY(self);
      return nil;
    }
  _format = RETAIN(format);
  _eglConfig = chooseConfig(_format, &_gbmFormat);
  if (_eglConfig == NULL)
    {
      NSLog(@"NextBSD: OpenGL: no EGL config for the pixel format");
      DESTROY(self);
      return nil;
    }
  if ([share isKindOfClass: [NextBSDGLContext class]])
    {
      _share = RETAIN(share);
      shared = ((NextBSDGLContext *)share)->_eglContext;
    }
  p_eglBindAPI(egl.api);
  _eglContext = p_eglCreateContext(egl.display, _eglConfig, shared,
				   egl.api == EGL_OPENGL_ES_API ? gles : NULL);
  if (_eglContext == EGL_NO_CONTEXT)
    {
      NSLog(@"NextBSD: OpenGL: eglCreateContext failed (0x%x)",
	    p_eglGetError());
      DESTROY(self);
      return nil;
    }
  _opacity = 1;
  _scale = 1;
  _buffers = calloc(MAX_GL_BUFFERS, sizeof(*_buffers));
  if (contexts == nil)
    contexts = NSCreateHashTable(NSNonOwnedPointerHashCallBacks, 4);
  NSHashInsert(contexts, self);
  return self;
}

- (id) initWithCGLContextObj: (void *)context
{
  NSDebugMLLog(@"OpenGL", @"not supported on NextBSD");
  DESTROY(self);
  return nil;
}

- (void) dealloc
{
  if (contexts != nil)
    NSHashRemove(contexts, self);
  if (currentContext == self)
    [NextBSDGLContext clearCurrentContext];
  [self _giveWindowBack];
  [self _destroySurface];
  if (_eglContext != NULL && egl.ok)
    p_eglDestroyContext(egl.display, _eglContext);
  free(_buffers);
  free(_readback);
  RELEASE(_view);
  RELEASE(_share);
  RELEASE(_format);
  [super dealloc];
}

- (void *) CGLContextObj
{
  return _eglContext;
}

- (NSOpenGLPixelFormat *) pixelFormat
{
  return _format;
}

- (void) copyAttributesFromContext: (NSOpenGLContext *)context
			  withMask: (unsigned long)mask
{
}

/* ---- the drawable ---- */

- (NSView *) view
{
  return _view;
}

- (void) setView: (NSView *)view
{
  if (view == nil)
    [NSException raise: NSInvalidArgumentException
		format: @"-setView: with nil"];
  if (view != _view)
    {
      [self _giveWindowBack];
      [self _destroySurface];
      ASSIGN(_view, view);
    }
  [self _updateDrawable];
}

- (void) clearDrawable
{
  [self _giveWindowBack];
  [self _destroySurface];
  _window = 0;
  _framePending = NO;
  DESTROY(_view);
}

- (void) update
{
  [self _updateDrawable];
}

- (NSSize) drawableSize
{
  return _eglSurface != NULL ? NSMakeSize(_width, _height) : NSZeroSize;
}

- (void) makeCurrentContext
{
  EGLSurface surf;

  [self _updateDrawable];
  surf = _eglSurface != NULL ? _eglSurface : EGL_NO_SURFACE;
  if (surf == EGL_NO_SURFACE && !egl.surfaceless)
    return;
  if (!p_eglMakeCurrent(egl.display, surf, surf, _eglContext))
    {
      NSDebugMLLog(@"OpenGL", @"eglMakeCurrent failed (0x%x)",
		   p_eglGetError());
      return;
    }
  currentContext = self;
}

/*
 * Make the EGL surface match the view: its window, its size in pixels,
 * and whether the frames can be the window's buffers (the view covers
 * the window). A change makes a new surface.
 */
- (void) _updateDrawable
{
  NextBSDServer	   *srv = server();
  NSWindow	   *win = [_view window];
  nextbsd_window_t *w;
  NSRect	    r;
  BOOL		    best, exclusive;
  int		    number, scale, width, height;

  w = (win != nil && srv != nil)
    ? [srv windowWithNumber: [win windowNumber]] : NULL;
  if (w == NULL || [_view isHiddenOrHasHiddenAncestor])
    {
      [self _giveWindowBack];
      [self _destroySurface];
      _window = 0;
      return;
    }
  number = w->number;
  /* The view in the window's base coordinates, then top-left. */
  r = [_view convertRect: [_view bounds] toView: nil];
  exclusive = fabs(NSMinX(r)) < 0.5 && fabs(NSMinY(r)) < 0.5
    && fabs(NSWidth(r) - NSWidth(w->frame)) < 0.5
    && fabs(NSHeight(r) - NSHeight(w->frame)) < 0.5;
  r.origin.y = NSHeight(w->frame) - NSMaxY(r);
  _viewRect = r;
  best = [_view respondsToSelector: @selector(wantsBestResolutionOpenGLSurface)]
    && [(id <NextBSDGLBestResolution>)_view
		  wantsBestResolutionOpenGLSurface];
  scale = best ? [srv backingScale] : 1;
  width = MAX(1, (int)lround(NSWidth(r) * scale));
  height = MAX(1, (int)lround(NSHeight(r) * scale));

  if (_eglSurface != NULL && number == _window && width == _width
      && height == _height && scale == _scale && exclusive == _exclusive)
    return;

  if (number != _window || !exclusive)
    [self _giveWindowBack];
  [self _destroySurface];
  _window = number;
  _width = width;
  _height = height;
  _scale = scale;
  _exclusive = exclusive;

  if (exclusive)
    {
      /* The formats and modifiers WindowServer composites, fastest
	 first (Broadcom UIF on a Pi 5). */
      uint32_t wsFormat = (_opacity != 0 || _gbmFormat == GBM_FORMAT_XRGB8888)
	? WS_FORMAT_XRGB8888 : WS_FORMAT_ARGB8888;
      uint64_t mods[WS_MAX_DMABUF_FORMATS];
      unsigned n = 0, i;

      for (i = 0; i < egl.formats.count; i++)
	if (egl.formats.formats[i].format == wsFormat)
	  mods[n++] = egl.formats.formats[i].modifier;
      if (n > 0 && p_gbm_surface_create_with_modifiers2 != NULL)
	_gbmSurface = p_gbm_surface_create_with_modifiers2(egl.gbm, width,
	  height, _gbmFormat, mods, n, GBM_BO_USE_RENDERING);
      else if (n > 0)
	_gbmSurface = p_gbm_surface_create_with_modifiers(egl.gbm, width,
	  height, _gbmFormat, mods, n);
      if (_gbmSurface == NULL)
	{
	  NSDebugMLLog(@"OpenGL", @"no %dx%d GPU buffers WindowServer takes;"
		       @" drawing through the window's surface", width, height);
	  _exclusive = NO;
	}
    }
  if (_gbmSurface == NULL)
    _gbmSurface = p_gbm_surface_create(egl.gbm, width, height, _gbmFormat,
				       GBM_BO_USE_RENDERING);
  if (_gbmSurface == NULL)
    {
      NSLog(@"NextBSD: OpenGL: can't make a %dx%d surface", width, height);
      return;
    }
  _eglSurface = p_eglCreatePlatformWindowSurface != NULL
    ? p_eglCreatePlatformWindowSurface(egl.display, _eglConfig, _gbmSurface,
				       NULL)
    : p_eglCreateWindowSurface(egl.display, _eglConfig,
			       (EGLNativeWindowType)_gbmSurface, NULL);
  if (_eglSurface == EGL_NO_SURFACE)
    {
      NSLog(@"NextBSD: OpenGL: eglCreateWindowSurface failed (0x%x)",
	    p_eglGetError());
      _eglSurface = NULL;
      p_gbm_surface_destroy(_gbmSurface);
      _gbmSurface = NULL;
      return;
    }
  /* A current context follows its view to the new surface. */
  if (currentContext == self)
    p_eglMakeCurrent(egl.display, _eglSurface, _eglSurface, _eglContext);
  NSDebugMLLog(@"OpenGL", @"%dx%d drawable (scale %d) for window %d, %s",
	       width, height, scale, number,
	       _exclusive ? "its buffers" : "copied into the window");
}

- (void) _destroySurface
{
  ws_connection_t *conn = [NextBSDServer connection];
  int		   i;

  if (_eglSurface != NULL)
    {
      if (p_eglGetCurrentContext() == _eglContext)
	{
	  if (egl.surfaceless)
	    p_eglMakeCurrent(egl.display, EGL_NO_SURFACE, EGL_NO_SURFACE,
			     _eglContext);
	  else
	    p_eglMakeCurrent(egl.display, EGL_NO_SURFACE, EGL_NO_SURFACE,
			     EGL_NO_CONTEXT);
	}
      p_eglDestroySurface(egl.display, _eglSurface);
      _eglSurface = NULL;
    }
  /* WindowServer keeps showing a buffer it has until the next commit,
     whatever happens to it here. */
  for (i = 0; i < _bufferCount; i++)
    {
      if (_buffers[i].buffer != NULL && conn != NULL)
	ws_buffer_destroy(conn, _buffers[i].buffer);
      memset(&_buffers[i], 0, sizeof(_buffers[i]));
    }
  _bufferCount = 0;
  if (_gbmSurface != NULL)
    {
      p_gbm_surface_destroy(_gbmSurface);
      _gbmSurface = NULL;
    }
}

/* Let the window's cairo surface present the window again. */
- (void) _giveWindowBack
{
  nextbsd_window_t *w;

  if (!_owner)
    return;
  _owner = NO;
  w = _window != 0 ? [server() windowWithNumber: _window] : NULL;
  if (w != NULL && w->glOwner == self)
    {
      w->glOwner = nil;
      [w->surface resumeAfterGL];
    }
}

/* ---- frames ---- */

- (struct nextbsd_gl_buffer *) _bufferFor: (struct gbm_bo *)bo
{
  ws_connection_t *conn = [NextBSDServer connection];
  struct nextbsd_gl_buffer *b;
  int		   i, fd;

  for (i = 0; i < _bufferCount; i++)
    if (_buffers[i].bo == bo)
      return &_buffers[i];
  if (_bufferCount == MAX_GL_BUFFERS)
    return NULL;
  b = &_buffers[_bufferCount];
  fd = p_gbm_bo_get_fd(bo);
  if (fd < 0)
    return NULL;
  b->buffer = ws_buffer_create_dmabuf(conn, p_gbm_bo_get_width(bo),
    p_gbm_bo_get_height(bo), (uint32_t)_scale,
    (_opacity != 0 || _gbmFormat == GBM_FORMAT_XRGB8888)
      ? WS_FORMAT_XRGB8888 : WS_FORMAT_ARGB8888,
    fd, p_gbm_bo_get_offset(bo, 0), p_gbm_bo_get_stride(bo),
    p_gbm_bo_get_modifier(bo));
  close(fd);
  if (b->buffer == NULL)
    {
      NSLog(@"NextBSD: OpenGL: WindowServer refused a GPU buffer: %s",
	    strerror(errno));
      return NULL;
    }
  b->bo = bo;
  _bufferCount++;
  NSDebugMLLog(@"OpenGL", @"GPU buffer %u: %ux%u, modifier 0x%llx",
	       ws_buffer_id(b->buffer), p_gbm_bo_get_width(bo),
	       p_gbm_bo_get_height(bo),
	       (unsigned long long)p_gbm_bo_get_modifier(bo));
  return b;
}

/* The frame's buffer becomes the window's: no copy. */
- (BOOL) _presentExclusive
{
  NextBSDServer	   *srv = server();
  ws_connection_t  *conn = [srv connection];
  nextbsd_window_t *w = [srv windowWithNumber: _window];
  struct gbm_bo	   *bo;
  struct nextbsd_gl_buffer *b;
  ws_rect_t	    all;

  if (w == NULL || conn == NULL)
    return NO;
  bo = p_gbm_surface_lock_front_buffer(_gbmSurface);
  if (bo == NULL)
    return NO;
  b = [self _bufferFor: bo];
  if (b == NULL)
    {
      p_gbm_surface_release_buffer(_gbmSurface, bo);
      return NO;
    }
  /* The window's cairo surface stops presenting it. */
  if (w->glOwner != self)
    {
      if (w->glOwner != nil)
	[(NextBSDGLContext *)w->glOwner _giveWindowBack];
      w->glOwner = self;
      [w->surface suspendForGL];
    }
  _owner = YES;
  all.x = 0;
  all.y = 0;
  all.width = (int32_t)ceil(NSWidth(w->frame));
  all.height = (int32_t)ceil(NSHeight(w->frame));
  ws_window_attach(conn, _window, b->buffer);
  ws_window_damage(conn, _window, &all, 1);
  ws_window_commit(conn, _window, WS_COMMIT_FRAME_DONE);
  b->busy = YES;
  return YES;
}

/* Copy the frame into the view's part of the window's back store. */
- (BOOL) _presentComposited
{
  nextbsd_window_t *w = [server() windowWithNumber: _window];
  NextBSDCairoShmSurface *surface = w != NULL ? w->surface : nil;
  cairo_surface_t  *store = [surface surface];
  cairo_surface_t  *frame;
  cairo_t	   *cr;
  size_t	    size = (size_t)_width * _height * 4;
  uint32_t	   *row;
  const uint8_t	   *src;
  double	    dx, dy;
  int		    fb = 0, pack = 4, x, y;
  BOOL		    opaque = _opacity != 0 || _gbmFormat == GBM_FORMAT_XRGB8888;

  if (store == NULL || w->glOwner != nil)
    return NO;
  if (size > _readbackSize)
    {
      free(_readback);
      _readback = malloc(size);
      _readbackSize = _readback != NULL ? size : 0;
      if (_readback == NULL)
	return NO;
    }
  /* The window's back buffer, whatever framebuffer the app has bound. */
  p_glGetIntegerv(NB_GL_FRAMEBUFFER_BINDING, &fb);
  p_glGetIntegerv(NB_GL_PACK_ALIGNMENT, &pack);
  if (fb != 0)
    p_glBindFramebuffer(NB_GL_FRAMEBUFFER, 0);
  p_glPixelStorei(NB_GL_PACK_ALIGNMENT, 4);
  p_glReadPixels(0, 0, _width, _height, NB_GL_RGBA, NB_GL_UNSIGNED_BYTE,
		 _readback);
  p_glPixelStorei(NB_GL_PACK_ALIGNMENT, pack);
  if (fb != 0)
    p_glBindFramebuffer(NB_GL_FRAMEBUFFER, (unsigned int)fb);

  /* GL's RGBA rows, bottom up, to cairo's native-endian ARGB, top down,
     in place: swap the rows, then the channels. */
  for (y = 0; y < _height / 2; y++)
    {
      uint32_t *a = (uint32_t *)_readback + (size_t)y * _width;
      uint32_t *b = (uint32_t *)_readback + (size_t)(_height - 1 - y) * _width;

      for (x = 0; x < _width; x++)
	{
	  uint32_t t = a[x];

	  a[x] = b[x];
	  b[x] = t;
	}
    }
  for (y = 0; y < _height; y++)
    {
      row = (uint32_t *)_readback + (size_t)y * _width;
      for (x = 0; x < _width; x++)
	{
	  src = (const uint8_t *)&row[x];
	  row[x] = ((uint32_t)(opaque ? 0xff : src[3]) << 24)
	    | ((uint32_t)src[0] << 16) | ((uint32_t)src[1] << 8) | src[2];
	}
    }
  frame = cairo_image_surface_create_for_data(_readback,
    opaque ? CAIRO_FORMAT_RGB24 : CAIRO_FORMAT_ARGB32, _width, _height,
    _width * 4);
  /* Drawing may have left a device offset (CairoGState). */
  cairo_surface_get_device_offset(store, &dx, &dy);
  cairo_surface_set_device_offset(store, 0, 0);
  cr = cairo_create(store);
  /* The store's units are points (its device scale is the backing
     scale); the frame has _scale pixels per point. */
  cairo_rectangle(cr, NSMinX(_viewRect), NSMinY(_viewRect),
		  NSWidth(_viewRect), NSHeight(_viewRect));
  cairo_clip(cr);
  cairo_translate(cr, NSMinX(_viewRect), NSMinY(_viewRect));
  cairo_scale(cr, NSWidth(_viewRect) / _width, NSHeight(_viewRect) / _height);
  cairo_set_source_surface(cr, frame, 0, 0);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_paint(cr);
  cairo_destroy(cr);
  cairo_surface_destroy(frame);
  cairo_surface_set_device_offset(store, dx, dy);
  [surface handleExposeRect: _viewRect];
  return YES;
}

- (void) flushBuffer
{
  NextBSDServer *srv = server();
  struct gbm_bo *bo;
  BOOL		 shown = NO;
  double	 limit;

  if (_eglSurface == NULL || srv == nil)
    return;
  if (p_eglGetCurrentContext() != _eglContext)
    p_eglMakeCurrent(egl.display, _eglSurface, _eglSurface, _eglContext);
  /* NSOpenGLCPSwapInterval 1: at most one frame per refresh. */
  if (_swapInterval > 0 && _framePending)
    {
      limit = monotonic() + 0.1;
      while (_framePending && monotonic() < limit)
	waitForEvents(srv, 20);
    }
  if (!_exclusive)
    shown = [self _presentComposited];
  p_eglSwapBuffers(egl.display, _eglSurface);
  if (_exclusive)
    shown = [self _presentExclusive];
  else if ((bo = p_gbm_surface_lock_front_buffer(_gbmSurface)) != NULL)
    p_gbm_surface_release_buffer(_gbmSurface, bo);
  if (shown)
    {
      _framePending = YES;
      _callbackDue = _frameTarget != nil;
    }
  else if (_frameTarget != nil)
    {
      /* Nothing to wait for: ask for the next frame soon anyway. */
      _callbackDue = YES;
      [self _scheduleCallback];
    }
  /* The next frame needs a buffer WindowServer isn't holding. */
  if (_exclusive && _gbmSurface != NULL
      && !p_gbm_surface_has_free_buffers(_gbmSurface))
    {
      limit = monotonic() + 1.0;
      while (_gbmSurface != NULL
	     && !p_gbm_surface_has_free_buffers(_gbmSurface)
	     && monotonic() < limit)
	waitForEvents(srv, 50);
    }
}

- (void) setFrameCallbackTarget: (id)target selector: (SEL)selector
{
  _frameTarget = target;
  _frameSelector = selector;
  /* Due when the frame on its way is on screen; with none, the display
     is ready now. */
  _callbackDue = target != nil;
  if (target != nil && !_framePending)
    [self _scheduleCallback];
}

- (BOOL) isFramePending
{
  return _framePending;
}

- (void) _scheduleCallback
{
  static NSArray *modes = nil;

  if (!_callbackDue || _frameTarget == nil)
    return;
  _callbackDue = NO;
  if (modes == nil)
    modes = [[NSArray alloc] initWithObjects: NSDefaultRunLoopMode,
      NSModalPanelRunLoopMode, NSEventTrackingRunLoopMode, nil];
  /* From the run loop, never from inside the event dispatch. */
  [[NSRunLoop currentRunLoop] performSelector: _frameSelector
				       target: _frameTarget
				     argument: self
					order: 0
					modes: modes];
}

/* ---- parameters ---- */

- (void) getValues: (long *)vals forParameter: (NSOpenGLContextParameter)param
{
  if (vals == NULL)
    return;
  switch (param)
    {
    case NSOpenGLCPSwapInterval:
      *vals = _swapInterval;
      break;
    case NSOpenGLCPSurfaceOpacity:
      *vals = _opacity;
      break;
    default:
      *vals = 0;
      break;
    }
}

- (void) setValues: (const long *)vals
      forParameter: (NSOpenGLContextParameter)param
{
  if (vals == NULL)
    return;
  switch (param)
    {
    case NSOpenGLCPSwapInterval:
      _swapInterval = *vals;
      break;
    case NSOpenGLCPSurfaceOpacity:
      if ((*vals != 0) != (_opacity != 0))
	{
	  /* Its buffers are of another format now. */
	  _opacity = *vals;
	  [self _giveWindowBack];
	  [self _destroySurface];
	  [self _updateDrawable];
	}
      break;
    default:
      break;
    }
}

- (int) currentVirtualScreen
{
  return 0;
}

- (void) setCurrentVirtualScreen: (int)screen
{
}

- (void) setFullScreen
{
  NSDebugMLLog(@"OpenGL", @"not supported on NextBSD");
}

- (void) setOffScreen: (void *)baseaddr
		width: (long)width
	       height: (long)height
	     rowbytes: (long)rowbytes
{
  NSDebugMLLog(@"OpenGL", @"not supported on NextBSD");
}

- (void) createTexture: (unsigned long)target
	      fromView: (NSView *)view
	internalFormat: (unsigned long)format
{
  NSDebugMLLog(@"OpenGL", @"not supported on NextBSD");
}

@end

#endif /* NEXTBSD_HAVE_GL */
