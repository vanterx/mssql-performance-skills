-- Source for usp_GetOrdersByCustomer
-- Captured from production at 2026-05-17 09:30 NZST
-- Used in /mssql-performance-review example

CREATE OR ALTER PROCEDURE dbo.usp_GetOrdersByCustomer
    @CustomerId NVARCHAR(50),
    @StartDate DATETIME = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @StartDate IS NULL
        SET @StartDate = DATEADD(DAY, -30, GETDATE());

    SELECT *
    FROM dbo.Orders
    WHERE CustomerId = @CustomerId
      AND OrderDate >= @StartDate
      AND DELETED_FLAG = 0
    ORDER BY OrderDate DESC;
END
GO
