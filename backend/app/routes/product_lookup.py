"""Product barcode lookup with shared Neon cache and free public data sources."""
import asyncio
import json
import re
import time
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from fastapi import APIRouter, HTTPException, Query
from sqlalchemy import select, text

from app.core.database import AsyncSessionLocal
from app.core.models import ProductCatalog

import html
import urllib.parse
import urllib.request
from html.parser import HTMLParser
import logging

router = APIRouter()
_LOOKUP_LOCKS: dict[str, asyncio.Lock] = {}
_NEGATIVE_CACHE: dict[str, float] = {}
_NEGATIVE_CACHE_SECONDS = 900
_PRICE_TTL = timedelta(days=7)


def _valid_ean13(code: str) -> bool:
    # يدعم GTIN-8 وUPC-A وEAN-13 وGTIN-14، ولا يعتبر صحة الرقم إثباتًا للتسجيل الرسمي.
    if len(code) not in {8, 12, 13, 14} or not code.isdigit():
        return False
    total = 0
    for position, digit in enumerate(reversed(code[:-1])):
        total += int(digit) * (3 if position % 2 == 0 else 1)
    return (10 - total % 10) % 10 == int(code[-1])


def _get_json(url: str) -> dict[str, Any] | None:
    request = Request(
        url,
        headers={
            "User-Agent": "IslamApp/1.0 (product lookup)",
            "Accept": "application/json",
        },
    )
    try:
        with urlopen(request, timeout=5) as response:
            if response.status != 200:
                return None
            data = json.loads(response.read().decode("utf-8"))
            return data if isinstance(data, dict) else None
    except (HTTPError, URLError, TimeoutError, ValueError, OSError):
        return None


def _off_product(code: str) -> dict[str, Any] | None:
    url = (
        f"https://world.openfoodfacts.org/api/v3/product/{code}.json"
        "?fields=code,product_name,brands,quantity,categories,countries,manufacturer,product_type"
    )
    payload = _get_json(url)
    if not payload or payload.get("status") != "success":
        return None

    product = payload.get("product") or {}
    name = str(product.get("product_name") or "").strip()
    if not name:
        return None

    return {
        "name": name,
        "brand": str(product.get("brands") or "").strip(),
        "quantity": str(product.get("quantity") or "").strip(),
        "category": str(product.get("categories") or "").split(",")[0].strip(),
        "origin_country": str(product.get("countries") or "").split(",")[0].strip(),
        "manufacturer": str(product.get("manufacturer") or "").strip(),
        "product_source": "Open Food Facts",
        "product_source_url": f"https://world.openfoodfacts.org/product/{code}",
        "verification_status": "partial",
    }


def _open_prices(code: str) -> dict[str, Any] | None:
    # Open Prices is community-contributed; accept only Egyptian-pound records with a valid date/value.
    query = urlencode({
        "product_code": code,
        "page_size": 50,
        "ordering": "-date",
    })
    payload = _get_json(f"https://prices.openfoodfacts.org/api/v1/prices?{query}")
    if not payload:
        return None

    rows = payload.get("results", [])
    if not isinstance(rows, list):
        return None

    candidates = []
    for row in rows:
        if not isinstance(row, dict) or str(row.get("currency", "")).upper() not in {
            "EGP", "LE", "GBP"
        }:
            continue
        try:
            amount = float(row.get("price"))
            observed = datetime.fromisoformat(str(row.get("date", ""))[:10]).date()
            if amount > 0:
                candidates.append((observed, amount))
        except (TypeError, ValueError):
            continue

    if not candidates:
        return None

    observed, amount = max(candidates, key=lambda item: item[0])
    product_name = next(
        (
            str(item.get("product_name") or "").strip()
            for item in rows
            if isinstance(item, dict)
            and str(item.get("product_name") or "").strip()
        ),
        "",
    )
    return {
        "price_amount": amount,
        "price_min": None,
        "price_max": None,
        "price_type": "unconfirmed",
        "price_unit": "unit",
        "price_source": "Open Prices",
        "price_source_url": "https://prices.openfoodfacts.org/",
        "price_observed_at": observed.isoformat(),
        "product_name": product_name,
    }


def _result(row: ProductCatalog | None, code: str) -> dict[str, Any]:
    if row is None:
        return {
            "barcode": code,
            "found": False,
            "barcode_format_valid": _valid_ean13(code),
            "verification_status": "not_found",
            "product": None,
            "price": None,
            "message": "لم يتم العثور على سجل لهذا الباركود في المصادر التي تم فحصها.",
        }

    return {
        "barcode": row.barcode,
        "found": True,
        "barcode_format_valid": _valid_ean13(row.barcode),
        "verification_status": row.verification_status,
        "product": {
            "name": row.product_name,
            "brand": row.brand,
            "quantity": row.quantity,
            "category": row.category,
            "manufacturer": row.manufacturer,
            "origin_country": row.origin_country,
            "source": row.product_source,
            "source_url": row.product_source_url,
            "updated_at": row.product_updated_at.isoformat()
            if row.product_updated_at else None,
        },
        "price": {
            "amount": row.price_amount,
            "min": row.price_min,
            "max": row.price_max,
            "type": row.price_type,
            "unit": row.price_unit,
            "source": row.price_source,
            "source_url": row.price_source_url,
            "observed_at": row.price_observed_at.isoformat()
            if row.price_observed_at else None,
            "updated_at": row.price_updated_at.isoformat()
            if row.price_updated_at else None,
            "checked_at": row.price_checked_at.isoformat()
            if row.price_checked_at else None,
        } if row.price_amount is not None or row.price_min is not None or row.price_max is not None else None,
        "message": None,
    }


@router.get("/lookup/{barcode}")
async def lookup_product(barcode: str, refresh: bool = Query(False)):
    code = barcode.strip()
    if not re.fullmatch(r"\d{8,14}", code):
        raise HTTPException(
            status_code=422,
            detail="اكتب باركودًا رقميًا من 8 إلى 14 خانة",
        )

    lock = _LOOKUP_LOCKS.setdefault(code, asyncio.Lock())
    async with lock:
        async with AsyncSessionLocal() as session:
            # قفل PostgreSQL ينسّق البحث عن نفس الكود حتى بين أكثر من عامل تشغيل للباك إند.
            await session.execute(
                text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
                {"lock_key": code},
            )
            found = await session.execute(
                select(ProductCatalog).where(ProductCatalog.barcode == code)
            )
            row = found.scalar_one_or_none()
            now = datetime.now(timezone.utc).replace(tzinfo=None)
            needs_product = row is None
            needs_price = (
                row is None
                or row.price_checked_at is None
                or now - _naive(row.price_checked_at) >= _PRICE_TTL
            )

            if row is not None and not refresh and not needs_price:
                return _result(row, code)

            if row is None and not refresh and _NEGATIVE_CACHE.get(code, 0) > time.monotonic():
                return _result(None, code)

            # استعلم عن المصدرين بالتوازي؛ الانتظار المتتابع كان قد يتجاوز مهلة الواجهة
            # (12 ثانية) عند تأخر المصدرين، رغم أن كل طلب خارجي له مهلة 5 ثوانٍ.
            product_task = (
                asyncio.to_thread(_off_product, code)
                if needs_product or refresh
                else asyncio.sleep(0, result=None)
            )
            price_task = (
                asyncio.to_thread(_open_prices, code)
                if needs_price or refresh
                else asyncio.sleep(0, result=None)
            )
            product_data, price_data = await asyncio.gather(product_task, price_task)

            if row is None and not product_data and not price_data:
                _NEGATIVE_CACHE[code] = time.monotonic() + _NEGATIVE_CACHE_SECONDS
                return _result(None, code)

            if row is None:
                row = ProductCatalog(
                    barcode=code,
                    product_name=(product_data or {}).get("name")
                    or (price_data or {}).get("product_name")
                    or "اسم المنتج غير متاح",
                    verification_status=(product_data or {}).get("verification_status", "partial"),
                    product_source=(product_data or {}).get("product_source", ""),
                    product_source_url=(product_data or {}).get("product_source_url", ""),
                    product_updated_at=now,
                )
                session.add(row)

            if product_data:
                for source_key, column in (
                    ("name", "product_name"),
                    ("brand", "brand"),
                    ("quantity", "quantity"),
                    ("category", "category"),
                    ("manufacturer", "manufacturer"),
                    ("origin_country", "origin_country"),
                    ("product_source", "product_source"),
                    ("product_source_url", "product_source_url"),
                    ("verification_status", "verification_status"),
                ):
                    value = product_data.get(source_key)
                    if value:
                        setattr(row, column, value)
                row.product_updated_at = now

            if price_data:
                row.price_amount = price_data["price_amount"]
                row.price_min = price_data["price_min"]
                row.price_max = price_data["price_max"]
                row.price_type = price_data["price_type"]
                row.price_unit = price_data["price_unit"]
                row.price_source = price_data["price_source"]
                row.price_source_url = price_data["price_source_url"]
                row.price_observed_at = datetime.fromisoformat(
                    price_data["price_observed_at"]
                )
                row.price_updated_at = now

            elif needs_price and row.price_amount is None:
                # Estimate only from at least three recent records with the same category and package size.
                if row.category and row.quantity:
                    comparable_result = await session.execute(
                        select(ProductCatalog).where(
                            ProductCatalog.barcode != code,
                            ProductCatalog.category == row.category,
                            ProductCatalog.quantity == row.quantity,
                            ProductCatalog.price_amount.is_not(None),
                            ProductCatalog.price_observed_at >= now - timedelta(days=90),
                            ProductCatalog.price_type.in_(["unconfirmed", "estimated"]),
                        ).limit(20)
                    )
                    comparable = [
                        item for item in comparable_result.scalars().all()
                        if item.price_amount and item.price_amount > 0
                    ]
                    if len(comparable) >= 3:
                        values = sorted(item.price_amount for item in comparable)
                        row.price_amount = values[len(values) // 2]
                        row.price_min = values[0]
                        row.price_max = values[-1]
                        row.price_type = "estimated"
                        row.price_unit = "unit"
                        row.price_source = "تقدير من منتجات مماثلة محفوظة في IslamApp"
                        row.price_source_url = ""
                        row.price_observed_at = max(
                            item.price_observed_at
                            for item in comparable
                            if item.price_observed_at
                        )
                        row.price_updated_at = now

            # Store the attempt time separately so a failed refresh does not make an old price look new.
            if needs_price:
                row.price_checked_at = now

            await session.commit()
            await session.refresh(row)
            _NEGATIVE_CACHE.pop(code, None)
            return _result(row, code)


def _naive(value: datetime) -> datetime:
    return value.replace(tzinfo=None) if value.tzinfo else value


# البحث بالاسم في أمازون مصر فقط — مستقل عن مسار الباركود


def _search_page_html(url: str) -> str:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "ar-EG,ar;q=0.9,en-US;q=0.8,en;q=0.7",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=12) as response:
            page = response.read(2_500_000).decode("utf-8", errors="ignore")
            title_match = re.search(r"<title[^>]*>(.*?)</title>", page, re.I | re.S)
            logging.warning(
                "Amazon product search diagnostic: status=%s bytes=%s title=%r blocked=%s",
                response.status,
                len(page),
                _clean_search_text(title_match.group(1))[:150] if title_match else "NO TITLE",
                bool(re.search(r"captcha|robot check|access denied|verify you are human", page, re.I)),
            )
            if "html" not in response.headers.get("Content-Type", "").lower():
                logging.warning("Amazon product search returned non-HTML content")
                return ""
            return page
    except Exception:
        logging.exception("Amazon product search request failed")
        return ""


def _clean_search_text(value: str) -> str:
    value = re.sub(r"<[^>]+>", " ", value or "")
    value = html.unescape(value)
    return re.sub(r"\s+", " ", value).strip()


def _products_from_json(value):
    products = []
    if isinstance(value, dict):
        kind = value.get("@type", "")
        if isinstance(kind, list):
            kind = " ".join(str(x) for x in kind)

        if "Product" in str(kind):
            offers = value.get("offers") or {}
            if isinstance(offers, list):
                offers = offers[0] if offers else {}
            price = offers.get("price") if isinstance(offers, dict) else None
            currency = offers.get("priceCurrency") if isinstance(offers, dict) else None
            name = value.get("name")
            url = value.get("url")
            if name and url:
                try:
                    numeric_price = float(str(price).replace(",", "")) if price is not None else None
                except (ValueError, TypeError):
                    numeric_price = None
                products.append({
                    "title": _clean_search_text(str(name)),
                    "url": str(url),
                    "price": numeric_price,
                    "currency": str(currency or "EGP"),
                })

        for child in value.values():
            products.extend(_products_from_json(child))
    elif isinstance(value, list):
        for child in value:
            products.extend(_products_from_json(child))
    return products



def _amazon_card_products(page: str, base_url: str) -> list[dict]:
    import html
    import re
    import logging
    from urllib.parse import urlparse

    results = []
    seen = set()

    def clean_text(value: str) -> str:
        value = html.unescape(value or "")
        value = re.sub(r"<[^>]+>", " ", value)
        value = re.sub(r"[\u200e\u200f\u202a-\u202e\u2066-\u2069]", "", value)
        return re.sub(r"\s+", " ", value).strip()

    def extract_price(card: str):
        # الأولوية للسعر الكامل الموجود داخل a-offscreen.
        match = re.search(
            r'<span[^>]*class=["\'][^"\']*\ba-offscreen\b[^"\']*["\'][^>]*>'
            r'(.*?)</span>',
            card,
            re.IGNORECASE | re.DOTALL,
        )

        if match:
            raw_price = clean_text(match.group(1))
            numbers = re.findall(r"\d+(?:,\d{3})*(?:\.\d+)?", raw_price)
            if numbers:
                try:
                    return float(numbers[0].replace(",", ""))
                except (ValueError, TypeError):
                    pass

        # بديل عند عدم وجود a-offscreen.
        whole = re.search(
            r'<span[^>]*class=["\'][^"\']*\ba-price-whole\b[^"\']*["\'][^>]*>'
            r'(.*?)</span>',
            card,
            re.IGNORECASE | re.DOTALL,
        )
        fraction = re.search(
            r'<span[^>]*class=["\'][^"\']*\ba-price-fraction\b[^"\']*["\'][^>]*>'
            r'(.*?)</span>',
            card,
            re.IGNORECASE | re.DOTALL,
        )

        if whole:
            whole_value = re.sub(r"\D", "", clean_text(whole.group(1)))
            fraction_value = re.sub(
                r"\D", "", clean_text(fraction.group(1))
            ) if fraction else "00"

            if whole_value:
                try:
                    return float(f"{whole_value}.{fraction_value[:2].ljust(2, '0')}")
                except ValueError:
                    pass

        return None

    # بطاقات نتائج البحث في أمازون.
    markers = list(re.finditer(
        r'<div\b(?=[^>]*\bdata-component-type=["\']s-search-result["\'])'
        r'(?=[^>]*\bdata-asin=["\']([A-Z0-9]{10})["\'])[^>]*>',
        page,
        re.IGNORECASE | re.DOTALL,
    ))

    logging.warning("Amazon search card markers found: %s", len(markers))

    parsed_base = urlparse(base_url)
    if parsed_base.netloc and not (
        parsed_base.netloc == "amazon.eg"
        or parsed_base.netloc.endswith(".amazon.eg")
    ):
        base_url = "https://www.amazon.eg"

    for index, marker in enumerate(markers):
        if len(results) >= 3:
            break

        asin_match = re.search(
            r'\bdata-asin=["\']([A-Z0-9]{10})["\']',
            marker.group(0),
            re.IGNORECASE,
        )
        if not asin_match:
            continue

        asin = asin_match.group(1).upper()
        if asin in seen:
            continue

        card_end = (
            markers[index + 1].start()
            if index + 1 < len(markers)
            else len(page)
        )
        card = page[marker.start():card_end]

        # استبعاد بطاقات النتائج الفارغة.
        if not card.strip():
            continue

        title = None

        # اسم المنتج من h2، مع دعم aria-label والنص الداخلي.
        title_match = re.search(
            r'<h2\b([^>]*)>(.*?)</h2>',
            card,
            re.IGNORECASE | re.DOTALL,
        )

        if title_match:
            attributes = title_match.group(1)
            aria_match = re.search(
                r'\baria-label=["\']([^"\']+)["\']',
                attributes,
                re.IGNORECASE,
            )

            if aria_match:
                title = clean_text(aria_match.group(1))
                title = re.sub(
                    r"^(الإعلان المدعوم|Sponsored)\s*[-:：]?\s*",
                    "",
                    title,
                    flags=re.IGNORECASE,
                )

            if not title:
                title = clean_text(title_match.group(2))

        if not title:
            continue

        price = extract_price(card)

        # إنشاء رابط المنتج مباشرةً من ASIN.
        product_url = f"https://www.amazon.eg/dp/{asin}"

        results.append({
            "name": title,
            "title": title,
            "price": price,
            "url": product_url,
            "image": None,
            "store": "Amazon Egypt",
            "source": "Amazon Egypt",
            "asin": asin,
        })
        seen.add(asin)

    logging.warning(
        "Amazon product extraction: candidates=%s results=%s",
        len(markers),
        len(results),
    )

    return results



def _extract_store_products(page: str, store: str, base_url: str, query: str):
    if not page:
        return []

    found = []
    scripts = re.findall(
        r'<script\b[^>]*type\s*=\s*["\']application/ld\+json["\'][^>]*>(.*?)</script>',
        page,
        re.I | re.S,
    )
    for script in scripts:
        try:
            found.extend(_products_from_json(json.loads(html.unescape(script))))
        except (ValueError, TypeError):
            continue

    # Always try Amazon search cards too; JSON-LD may exist but contain no usable search results.
    found.extend(_amazon_card_products(page, base_url))

    results = []
    seen = set()
    for item in found:
        title = _clean_search_text(str(item.get("title") or ""))
        url = urllib.parse.urljoin(base_url, str(item.get("url") or "").strip())
        if not title or not url:
            continue
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("http", "https") or parsed.netloc.lower() not in {"amazon.eg", "www.amazon.eg"}:
            continue
        # Ignore Amazon links that are not product detail pages.
        if not re.search(r"/(?:dp|gp/product)/[A-Z0-9]{8,14}", parsed.path, re.I):
            continue
        key = (title.casefold(), url.split("?", 1)[0])
        if key in seen:
            continue
        seen.add(key)
        try:
            price = float(item.get("price")) if item.get("price") is not None else None
        except (ValueError, TypeError):
            price = None
        results.append({
            "title": title,
            "store": "Amazon Egypt",
            "url": url,
            "price": price if price is not None and price > 0 else None,
            "currency": "EGP" if price is not None and price > 0 else None,
            "price_basis": "published" if price is not None and price > 0 else None,
        })
        if len(results) >= 3:
            break
    logging.warning("Amazon product extraction: candidates=%s results=%s", len(found), len(results))
    return results


def _search_store_products(query: str, store: str = "Amazon Egypt"):
    base_url = "https://www.amazon.eg"
    search_url = base_url + "/s?k=" + urllib.parse.quote_plus(query)
    try:
        page = _search_page_html(search_url)
        results = _extract_store_products(page, "Amazon Egypt", base_url, query)
        logging.warning(
            "Product search extraction: query=%r page_bytes=%s results=%s",
            query, len(page), len(results),
        )
        return results
    except Exception:
        logging.exception("Amazon product search extraction failed")
        return []


@router.get("/search")
async def search_products_by_name(query: str):
    query = query.strip()
    if len(query) < 2:
        raise HTTPException(status_code=400, detail="اكتب اسم منتج مكوّنًا من حرفين على الأقل")
    if len(query) > 120:
        raise HTTPException(status_code=400, detail="اسم المنتج طويل جدًا")

    results = await asyncio.to_thread(_search_store_products, query)
    prices = [item["price"] for item in results if isinstance(item.get("price"), (int, float))]
    return {
        "query": query,
        "found": bool(results),
        "results": results,
        "price_range": {
            "min": min(prices),
            "max": max(prices),
            "currency": "EGP",
            "basis": "published_prices",
        } if len(prices) >= 2 else None,
        "message": None if results else (
            "لم نتمكن من استخراج نتائج أمازون حاليًا. جرّب فتح رابط البحث في أمازون مباشرة."
        ),
        "store_search_urls": {
            "amazon": "https://www.amazon.eg/s?k=" + urllib.parse.quote_plus(query),
        },
    }