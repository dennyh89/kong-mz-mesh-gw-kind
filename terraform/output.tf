output "mesh_id" {
  value     = konnect_mesh_control_plane.kind-mesh.id
}
output "mesh_name" {
  value     = konnect_mesh_control_plane.kind-mesh.name
}
output "cp_name" {
  value     = konnect_gateway_control_plane.mesh-ingress.name
}
output "cp_id" {
  value     = konnect_gateway_control_plane.mesh-ingress.id
}
output "cp_endpoint" {
  value     = substr(konnect_gateway_control_plane.mesh-ingress.config.control_plane_endpoint,8,-1)
}
output "cp_telemetry_endpoint" {
  value     = substr(konnect_gateway_control_plane.mesh-ingress.config.telemetry_endpoint,8,-1)
}
