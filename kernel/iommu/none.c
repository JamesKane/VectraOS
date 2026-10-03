// none.c: no IOMMU (aarch64 until SMMUv3, M5 step 6d): every DMA domain is
// pass-through (obj/device.c).

static void iommu_init(void) {}
static vx_status iommu_attach(dma_domain *d) {
  (void)d;
  return VX_OK;
}
static void iommu_detach(dma_domain *d) { (void)d; }
static bool iommu_map(dma_domain *d, uint64_t iova, const uint64_t *pa, uint64_t pages, uint32_t options) {
  (void)d, (void)iova, (void)pa, (void)pages, (void)options;
  return false;
}
static void iommu_unmap(dma_domain *d, uint64_t iova, uint64_t pages) { (void)d, (void)iova, (void)pages; }
