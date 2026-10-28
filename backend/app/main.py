from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute
from fastmcp.utilities.lifespan import combine_lifespans

from app import client_versions
from app.api.identity import EPOCH_HEADER, SERVER_ID_HEADER, SERVER_TIME_HEADER, IdentityHeadersMiddleware
from app.api.routes import router, unchecked_router
from app.client_versions import API_LEVEL_HEADER, MIN_CLIENT_LEVEL_HEADER, ClientVersionMiddleware
from app.config import get_settings
from app.errors import DomainError
from app.mcp_server import mcp
from app.schemas.base import FieldIssue, Problem, error_loc, error_message
from app.services import scheduler
from app.services.push import apns


def _operation_id(route: APIRoute) -> str:
    return route.name


def create_app() -> FastAPI:
    # Resolved now, so a bad QUICKR_MIN_CLIENT_LEVEL_* override warns at boot, not on a request.
    client_versions.current()
    mcp_app = mcp.http_app(path="/")
    app = FastAPI(
        title="quickR API",
        version="1.0.0",
        description="Config-driven topics, questions and answer entries.",
        # Entered in order, exited in reverse: the scheduler stops before APNs closes.
        lifespan=combine_lifespans(apns.lifespan, scheduler.lifespan, mcp_app.lifespan),
        generate_unique_id_function=_operation_id,
    )
    # Innermost first. Feed pages and entry lists are large, repetitive JSON (~10x smaller
    # compressed). The client-version check refuses an outdated client before any route runs,
    # inside the identity middleware, so a 426 carries the identity and level headers. The
    # identity middleware answers unhandled errors itself, so they carry its headers; CORS
    # wraps it, so those answers get CORS headers too.
    app.add_middleware(GZipMiddleware, minimum_size=1024)
    app.add_middleware(ClientVersionMiddleware)
    app.add_middleware(IdentityHeadersMiddleware)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=get_settings().cors_origins,
        allow_methods=["*"],
        allow_headers=["*"],
        expose_headers=[
            SERVER_ID_HEADER,
            EPOCH_HEADER,
            SERVER_TIME_HEADER,
            API_LEVEL_HEADER,
            MIN_CLIENT_LEVEL_HEADER,
        ],
    )

    @app.exception_handler(RequestValidationError)
    async def _request_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        issues = [
            FieldIssue(
                loc=error_loc(err.get("loc", ()), err.get("ctx")),
                message=error_message(str(err.get("msg", ""))),
            )
            for err in exc.errors()
        ]
        body = Problem(code="invalid_request", detail="request validation failed", errors=issues)
        return JSONResponse(status_code=422, content=body.model_dump(mode="json"))

    @app.exception_handler(DomainError)
    async def _domain_error(_: Request, exc: DomainError) -> JSONResponse:
        body = Problem(code=exc.code, detail=exc.detail, errors=exc.errors)
        return JSONResponse(status_code=exc.status_code, content=body.model_dump(mode="json"))

    app.include_router(unchecked_router, prefix="/api/v1")
    app.include_router(router, prefix="/api/v1")
    app.mount("/mcp", mcp_app)
    return app


app = create_app()
