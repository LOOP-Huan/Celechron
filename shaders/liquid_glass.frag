#include <flutter/runtime_effect.glsl>

// ImageFilter.shader owns the first vec2 and sampler. The input is the current
// render pass, NOT the ClipRRect bounds of the glass widget.
uniform vec2 u_textureSize;
uniform vec2 u_viewSize;
uniform vec2 u_cardSize;
uniform vec3 u_localX;
uniform vec3 u_localY;
uniform vec4 u_toView;
uniform float u_radius;
uniform float u_refraction;
uniform sampler2D u_backdrop;

out vec4 fragColor;

vec2 viewDelta(vec2 local) {
  return vec2(dot(u_toView.xy, local), dot(u_toView.zw, local));
}

vec2 backdropUV(vec2 viewPoint) {
  vec2 halfTexel = vec2(0.5) / u_textureSize;
  vec2 uv = clamp(viewPoint / u_viewSize, halfTexel, vec2(1.0) - halfTexel);
  // The geometry stays top-left oriented; only the GLES input texture flips.
  #ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
  #endif
  return uv;
}

vec4 sampleBackdrop(vec2 viewPoint) {
  // Flutter 3.38 binds an ImageFilter.shader input with nearest sampling.
  // Reconstruct between physical texel centers explicitly, so refraction of
  // another surface's text does not magnify pixels or snap during scrolling.
  vec2 pixel = clamp(backdropUV(viewPoint) * u_textureSize - 0.5,
                     vec2(0.0), u_textureSize - 1.0);
  vec2 lower = floor(pixel);
  vec2 fraction = pixel - lower;
  vec2 uv0 = (lower + 0.5) / u_textureSize;
  vec2 uv1 = (min(lower + 1.0, u_textureSize - 1.0) + 0.5) / u_textureSize;
  vec4 top = mix(texture(u_backdrop, uv0),
                 texture(u_backdrop, vec2(uv1.x, uv0.y)), fraction.x);
  vec4 bottom = mix(texture(u_backdrop, vec2(uv0.x, uv1.y)),
                    texture(u_backdrop, uv1), fraction.x);
  // The input is premultiplied RGBA; interpolation must preserve that form.
  return mix(top, bottom, fraction.y);
}

float roundedDistance(vec2 p, vec2 halfSize, float radius) {
  vec2 q = abs(p) - halfSize + radius;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

void main() {
  vec2 viewPoint = FlutterFragCoord().xy / u_textureSize * u_viewSize;
  vec3 point = vec3(viewPoint, 1.0);
  vec2 local = vec2(dot(u_localX, point), dot(u_localY, point));
  vec2 halfSize = u_cardSize * 0.5;
  vec2 q = local - halfSize;
  float radius = clamp(u_radius, 0.0, min(halfSize.x, halfSize.y));
  float distance = roundedDistance(q, halfSize, radius);
  if (distance >= 0.6) {
    // Undistorted viewPoint maps straight back to this input texel center.
    fragColor = texture(u_backdrop, backdropUV(viewPoint));
    return;
  }

  // This is the same rounded thickness profile as the approved WebGL sample.
  float depth = max(-distance, 0.0);
  float bevel = min(23.0, max(1.0, min(halfSize.x, halfSize.y)));
  float t = clamp(depth / bevel, 0.0, 1.0);
  float arc = sqrt(max(0.0, 1.0 - (1.0 - t) * (1.0 - t)));
  vec2 outward = normalize(vec2(
      roundedDistance(q + vec2(0.5, 0.0), halfSize, radius) -
          roundedDistance(q - vec2(0.5, 0.0), halfSize, radius),
      roundedDistance(q + vec2(0.0, 0.5), halfSize, radius) -
          roundedDistance(q - vec2(0.0, 0.5), halfSize, radius)) + vec2(0.00001));
  float slope = (20.0 / bevel) * (1.0 - t) / max(0.12, arc);
  vec3 normal = normalize(vec3(outward * slope, 1.0));
  vec3 ray = refract(vec3(0.0, 0.0, -1.0), normal, 1.0 / 1.46);
  float thickness = 8.0 + 20.0 * arc;
  vec2 bend = ray.xy / max(0.25, abs(ray.z)) * thickness;
  vec2 optical = (q / 1.018 - q + bend) * u_refraction;
  vec2 refracted = viewPoint + viewDelta(optical);
  vec4 glass = sampleBackdrop(refracted);

  // A native Gaussian filter smooths this transmitted scene after refraction.
  // A sparse in-shader kernel would leave separated copies of small glyphs.

  float fresnel = 0.025 + 0.975 * pow(1.0 - normal.z, 5.0);
  vec2 lightDirection = vec2(-0.55, -0.83);
  vec3 light = normalize(vec3(lightDirection, 0.65));
  float reflection = pow(max(dot(normal,
      normalize(light + vec3(0.0, 0.0, 1.0))), 0.0), 14.0);
  float rim = exp(-pow((distance + 0.8) / 0.75, 2.0));
  float lip = exp(-pow((depth - 3.0) / 1.5, 2.0));
  float facing = dot(outward, normalize(lightDirection));
  float highlight = reflection * 0.10 + fresnel * 0.13 +
      rim * (0.24 + 0.32 * max(facing, 0.0));
  // Preserve premultiplied alpha, including transparent ancestor surfaces.
  glass.rgb = mix(glass.rgb, vec3(glass.a), clamp(highlight, 0.0, 0.62));
  glass.rgb *= 1.0 - lip * 0.075 * max(-facing, 0.0);
  float mask = 1.0 - smoothstep(-0.6, 0.6, distance);
  // Interior pixels need no second copy of their undistorted background.
  if (mask >= 1.0) {
    fragColor = glass;
  } else {
    fragColor = mix(texture(u_backdrop, backdropUV(viewPoint)), glass, mask);
  }
}
