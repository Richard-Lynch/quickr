from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute

from app.api.routes import router
from app.config import get_settings
from app.errors import DomainError
from app.mcp_server import mcp
from app.schemas.api import Problem


def _operation_id(route: APIRoute) -> str:
    return route.name


def create_app() -> FastAPI:
    mcp_app = mcp.http_app(path="/")
    app = FastAPI(
        title="Quicker API",
        version="1.0.0",
        description="Config-driven topics, questions and answer sessions.",
        lifespan=mcp_app.lifespan,
        generate_unique_id_function=_operation_id,
    )
    app.add_middleware(
        CORSMiddleware,
        allow_origins=get_settings().cors_origins,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.exception_handler(DomainError)
    async def _domain_error(_: Request, exc: DomainError) -> JSONResponse:
        body = Problem(code=exc.code, detail=exc.detail, errors=exc.errors)
        return JSONResponse(status_code=exc.status_code, content=body.model_dump(mode="json"))

    app.include_router(router, prefix="/api/v1")
    app.mount("/mcp", mcp_app)
    return app


app = create_app()
