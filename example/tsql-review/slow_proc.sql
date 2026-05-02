-- Example stored procedure demonstrating common T-SQL anti-patterns.
-- Used as input for /tsql-review.

CREATE OR ALTER PROCEDURE dbo.GetCustomerReport
    @status      NVARCHAR(50) = NULL,
    @startDate   NVARCHAR(20) = NULL,
    @sortColumn  NVARCHAR(50) = 'OrderDate',
    @email       NVARCHAR(200) = NULL
AS
BEGIN
    -- T1: SELECT * — no explicit column list
    -- T5: @startDate is NVARCHAR but OrderDate is DATE — implicit conversion
    -- T4: YEAR() wraps indexed column — non-sargable
    -- T6: Leading wildcard LIKE
    -- T7: Explicit cursor
    -- T16: = NULL instead of IS NULL
    -- T19: No TRY/CATCH around DML
    -- T29: Dynamic SQL via string concatenation
    -- T38: Missing schema prefix

    DECLARE @sql NVARCHAR(MAX)

    -- T29 / T31: user-supplied sort column concatenated directly
    SET @sql = N'SELECT * FROM Orders WHERE 1=1'

    IF @status IS NOT NULL
        SET @sql = @sql + N' AND Status = ''' + @status + N''''

    IF @startDate IS NOT NULL
        -- T5: NVARCHAR parameter vs DATE column
        SET @sql = @sql + N' AND OrderDate >= ''' + @startDate + N''''

    IF @email IS NOT NULL
        -- T6: leading wildcard
        SET @sql = @sql + N' AND Email LIKE ''%' + @email + N''''

    -- T29: unparameterized EXEC
    -- T30: EXEC(@string) not sp_executesql
    SET @sql = @sql + N' ORDER BY ' + @sortColumn
    EXEC(@sql)

    -- T4: YEAR() on indexed column
    SELECT * FROM Orders
    WHERE YEAR(OrderDate) = 2024
      AND CustomerId = 42

    -- T7: cursor for row-by-row update
    DECLARE @orderId INT
    DECLARE order_cur CURSOR FOR
        SELECT OrderId FROM Orders WHERE Status = 'Pending'

    OPEN order_cur
    FETCH NEXT FROM order_cur INTO @orderId
    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- T19: DML with no TRY/CATCH
        -- T20: no explicit transaction
        UPDATE Orders SET ProcessedAt = GETDATE() WHERE OrderId = @orderId
        EXEC dbo.ProcessOrder @orderId
        FETCH NEXT FROM order_cur INTO @orderId
    END
    CLOSE order_cur
    DEALLOCATE order_cur

    -- T16: = NULL always returns no rows
    SELECT * FROM Customers WHERE DeletedAt = NULL

    -- T38: missing schema prefix
    SELECT * FROM Customers

    -- T43: INSERT without column list
    INSERT INTO AuditLog VALUES (@orderId, GETDATE(), 'processed')
END
